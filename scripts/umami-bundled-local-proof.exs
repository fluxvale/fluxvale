# The Umami bundled-database local proof (#612 S4 — the OQ #3
# takeover's lifecycle legs, run where they're actually observable).
#
# Usage (host, k3d stack up, from apps/platform):
#   kubectl --context k3d-fluxvale config view --raw > /tmp/opencode/kc.yaml
#   MIX_ENV=dev mix run ../../scripts/umami-bundled-local-proof.exs /tmp/opencode/kc.yaml
#
# What it proves, through the platform's own code paths (the action →
# Oban → DeployInstance pipeline runs in this very BEAM — dev's queue
# config is the real one):
#
#   1. the seeded bundled row creates + deploys through the platform:
#      instance :running, pod = app container + bundled PostgreSQL init
#      container, readiness confirmed by the real reconcile cron,
#   2. the takeover guard: a crafted DATABASE_URL on this row is
#      refused loudly (D6), live against the seeded row,
#   3. health: /api/heartbeat answers 200 ok through the edge URL,
#   4. first-run: the default admin (upstream's first migration into
#      the BUNDLED database) signs in over the public API,
#   5. RESTART leg: the pod is deleted; init ordering re-boots the
#      pair; the admin still signs in — the database rode the PVC,
#   6. STOP/START legs: the platform's own stop/start actions scale
#      0⇄1; the admin still signs in after each — the storage-only
#      interlude persisted the data,
#   7. teardown removes the namespace and the row.
#
# Why the Cluster row points at a temp kubeconfig: the platform's
# provider reads the row's `kubeconfig_ref` (K8s.kubeconfig/1), and a
# host-run `mix run` has no in-cluster service account — the
# private-access proof's stance (scripts/private-access-local-proof.exs).
# The original value is restored on exit.
#
# CI carries the same legs through the UI path
# (apps/e2e/tests/umami-lifecycle.spec.ts, the ephemeral stack); this
# script is the headless complement — no browser, no bootstrap, direct
# asserts on the k8s objects.

defmodule UmamiBundledLocalProof do
  @moduledoc false

  require Logger

  alias FluxVale.Catalog.App
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.Cluster
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Seeds

  @proof_email "umami-takeover-proof@fluxvale.com"
  # admin/umami — upstream's first migration seeds it (the version's
  # first-run contract, ADR-0034 Am. 2).
  # Paren delimiters: ~s{...} would eat the JSON's braces as its own.
  @default_admin ~s({"username":"admin","password":"umami"})

  def main([kubeconfig_path]) do
    Logger.configure(level: :warning)
    Process.put(:failures, 0)

    cluster = point_cluster_at(kubeconfig_path)

    try do
      proof()
    after
      restore_cluster(cluster)
    end

    summarize()
  end

  def main(_other) do
    IO.puts("usage: mix run umami-bundled-local-proof.exs <kubeconfig-path>")
    System.halt(2)
  end

  defp proof do
    # --- the real rows, converged into dev ----------------------------
    # seed_pricing! only when the ladder is missing: the guarded size
    # delete refuses while OTHER lanes' live capture fixtures still
    # reference their sizes, and this proof adds no sizes — the ladder
    # ships converged or it doesn't need converging here.
    unless size_seeded?("medium"), do: Seeds.seed_pricing!()
    Seeds.seed_catalog!()

    versions =
      "umami"
      |> App.get_by_slug!(authorize?: false)
      |> Ash.load!([:app_versions], authorize?: false)
      |> Map.fetch!(:app_versions)

    bundled = Enum.find(versions, &(&1.version == "3.4.1-bundled"))
    check(bundled != nil, "the bundled row seeds (3.4.1-bundled)")

    # --- create + deploy through the platform -------------------------
    {:ok, user} = ensure_user()

    instance =
      Instance.create!(
        %{
          name: "Umami takeover proof #{System.unique_integer([:positive])}",
          app_version_id: bundled.id,
          env_vars: %{
            "APP_SECRET" => "proof-secret-#{System.unique_integer([:positive])}-0123456789abcdef"
          }
        },
        actor: user,
        authorize?: false
      )

    check(instance.backing_services != [], "create snapshots the bundled postgres")
    check_refuses_takeover(user, bundled)

    instance
    |> Ash.Changeset.for_update(:deploy, %{}, authorize?: false)
    |> Ash.update!()

    # The real Oban worker (this BEAM, dev queues) runs DeployInstance.
    instance = await_status(instance.id, [:starting, :error], 90_000)
    namespace = "fluxvale-app-#{instance.id}"
    check(instance.status == :starting, "the deploy op applied (status :starting)")

    await_pod_ready(namespace, 8 * 60_000)
    instance = await_status(instance.id, [:running, :error], 240_000)
    check(instance.status == :running, "the reconciler confirmed :running")

    check_pod_shape(namespace)

    # --- health through the edge URL ----------------------------------
    url = "https://#{instance.slug}.#{base_domain()}"
    heartbeat = http_get("#{url}/api/heartbeat")
    check(heartbeat["ok"] == true, "GET /api/heartbeat answers 200 ok through the edge")

    # --- first-run: the default admin lives in the BUNDLED database ---
    {login_status, _} = login(url)
    check(login_status == 200, "the first-run default admin signs in (got #{login_status})")

    # The persistence witness is WRITTEN state, not the admin: the
    # first migration re-seeds admin/umami on an empty database, so a
    # wiped volume still signs in. A website created through the
    # public API exists only in data that survives the legs.
    marker = "persist-#{System.unique_integer([:positive])}"
    token = login_token(url)
    create_witness_website(url, token, marker)

    # --- RESTART leg: destroy the pod → data persists -----------------
    kubectl(["-n", namespace, "delete", "pod", "-l", "app.kubernetes.io/name=app"])
    # The delete returns when the pod object is gone; readyReplicas
    # can still read 1 for the dead pod on an immediate poll — wait
    # out the 0 before waiting for the replacement.
    await_replicas(namespace, 0, 60_000)
    await_pod_ready(namespace, 6 * 60_000)
    {restart_login, _} = login(url)
    check(restart_login == 200, "RESTART leg: the admin still signs in (got #{restart_login})")
    witness_website(url, login_token(url), marker, "RESTART leg")

    # --- STOP leg: the platform's own action, storage-only ------------
    Ash.get!(Instance, instance.id, authorize?: false)
    |> Ash.Changeset.for_update(:stop, %{}, authorize?: false)
    |> Ash.update!()

    await_replicas(namespace, 0, 60_000)
    {stopped_login, _} = login(url)

    check(
      stopped_login != 200,
      "STOP leg: the instance answers nothing while stopped (got #{stopped_login})"
    )

    # --- START leg: scale back, the data persisted --------------------
    Ash.get!(Instance, instance.id, authorize?: false)
    |> Ash.Changeset.for_update(:start, %{}, authorize?: false)
    |> Ash.update!()

    await_pod_ready(namespace, 6 * 60_000)
    {started_login, _} = login(url)
    check(started_login == 200, "START leg: the admin still signs in (got #{started_login})")
    witness_website(url, login_token(url), marker, "START leg")

    # --- teardown ------------------------------------------------------
    # The :delete ACTION (not the raw destroy): deployed rows flip to
    # :deleting and the AshOban job tears down the namespace and
    # hard-deletes the row — this BEAM's worker runs it while the
    # Cluster row still points at the temp kubeconfig.
    Instance.delete(instance.id, authorize?: false)

    await_namespace_gone(namespace, 300_000)
    pass("teardown removed the namespace and the row")
  end

  # The takeover guard, live against the seeded row: a crafted
  # DATABASE_URL must be refused (D6) — proven before the deploy, on
  # the same row the deploy then uses.
  defp check_refuses_takeover(user, bundled) do
    crafted =
      Instance.create(
        %{
          name: "takeover craft",
          app_version_id: bundled.id,
          env_vars: %{"DATABASE_URL" => "postgresql://evil@evil/evil"}
        },
        actor: user,
        authorize?: false
      )

    case crafted do
      {:error, %Ash.Error.Invalid{errors: errors}} ->
        check(
          Enum.any?(errors, &(&1.message =~ "bundled backing service")),
          "a user DATABASE_URL is rejected loudly on the bundled row"
        )

      _unexpected ->
        fail("a user DATABASE_URL was ACCEPTED on the bundled row (D6 broken)")
    end
  end

  defp ensure_user do
    case User.get_by_email(@proof_email, authorize?: false) do
      {:ok, user} ->
        {:ok, user}

      {:error, _not_found} ->
        code_ref = :umami_proof_code
        :persistent_term.put(code_ref, nil)

        deliver = fn _recipient, code ->
          :persistent_term.put(code_ref, code)
          {:ok, %{}}
        end

        FluxVale.Identity.Operations.RequestAuthCode.call(@proof_email, deliver)
        code = :persistent_term.get(code_ref, nil)
        {:ok, user, _token} = FluxVale.Identity.Operations.VerifyAuthCode.call(@proof_email, code)
        {:ok, user}
    end
  end

  # The shared dev DB's ladder check (see proof/0's seeding note).
  defp size_seeded?(slug) do
    require Ash.Query

    match?(
      {:ok, _size},
      Ash.Query.filter(FluxVale.Pricing.Size, slug == ^slug)
      |> Ash.read_one(authorize?: false)
    )
  end

  # --- cluster row plumbing (the private-access proof's stance) -------

  defp point_cluster_at(kubeconfig_path) do
    cluster = Cluster.get_by_name!("local", authorize?: false)
    original = cluster.kubeconfig_ref

    cluster
    |> Ash.Changeset.for_update(:update, %{kubeconfig_ref: kubeconfig_path}, authorize?: false)
    |> Ash.update!()

    %{id: cluster.id, original: original}
  end

  defp restore_cluster(%{id: id, original: original}) do
    Cluster
    |> Ash.get!(id, authorize?: false)
    |> Ash.Changeset.for_update(:update, %{kubeconfig_ref: original}, authorize?: false)
    |> Ash.update!()
  rescue
    _error -> :ok
  end

  # --- waiters ---------------------------------------------------------

  defp await_status(instance_id, statuses, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_status_loop(instance_id, statuses, deadline)
  end

  defp await_status_loop(instance_id, statuses, deadline) do
    instance = Ash.get!(Instance, instance_id, authorize?: false)

    cond do
      instance.status in statuses ->
        instance

      instance.status == :error ->
        fail("instance hit :error: #{instance.status_message}")
        instance

      System.monotonic_time(:millisecond) > deadline ->
        fail("status never reached #{inspect(statuses)} (stuck at #{instance.status})")
        instance

      true ->
        Process.sleep(2_000)
        await_status_loop(instance_id, statuses, deadline)
    end
  end

  defp await_pod_ready(namespace, timeout) do
    await_condition(
      ["-n", namespace, "get", "deploy", "app", "-o", "jsonpath={.status.readyReplicas}"],
      &(&1 == "1"),
      timeout,
      "pod never became ready in #{namespace}"
    )
  end

  defp await_replicas(namespace, replicas, timeout) do
    await_condition(
      ["-n", namespace, "get", "deploy", "app", "-o", "jsonpath={.spec.replicas}"],
      &(&1 == "#{replicas}"),
      timeout,
      "replicas never reached #{replicas} in #{namespace}"
    )
  end

  defp await_namespace_gone(namespace, timeout) do
    await_condition(
      ["get", "ns", namespace, "-o", "name"],
      &(&1 == ""),
      timeout,
      "namespace #{namespace} never went away"
    )
  end

  defp await_condition(args, matcher, timeout, message) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_condition_loop(args, matcher, message, deadline)
  end

  defp await_condition_loop(args, matcher, message, deadline) do
    out = kubectl(args, best_effort: true)

    cond do
      matcher.(out) ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        fail("#{message} (last: #{inspect(out)})")

      true ->
        Process.sleep(2_000)
        await_condition_loop(args, matcher, message, deadline)
    end
  end

  defp check_pod_shape(namespace) do
    out =
      kubectl([
        "-n",
        namespace,
        "get",
        "pod",
        "-l",
        "app.kubernetes.io/name=app",
        "-o",
        "jsonpath={.items[0].status.initContainerStatuses[*].name} {.items[0].status.containerStatuses[*].name}"
      ])

    names = out |> String.split() |> MapSet.new()

    check(
      MapSet.subset?(MapSet.new(["app", "postgres"]), names),
      "pod = app + postgres init container"
    )
  end

  # --- probes ----------------------------------------------------------

  defp base_domain, do: Application.fetch_env!(:flux_vale, :instances_base_domain)

  # curl over System.cmd: the edge cert is self-signed (-k), and the
  # app runs Finch/Req — inets is not guaranteed started in the tree.
  # --resolve: this host's resolver refuses *.lvh.me wildcards (Quad9
  # REFUSES the domain), so the edge URL is pinned to the local k3d
  # load balancer the way CI's /etc/hosts does it — the Host header,
  # not DNS, is what routes at Traefik.
  defp curl_args(url, extra) do
    uri = URI.parse(url)
    ["-skm", "10", "--resolve", "#{uri.host}:443:127.0.0.1" | extra]
  end

  defp http_get(url) do
    {body, 0} = System.cmd("curl", curl_args(url, [url]))

    case Jason.decode(body) do
      {:ok, json} -> json
      _ -> %{}
    end
  end

  # login/1's body-capturing sibling: the legs need the token to write
  # and read the witness website through the public API.
  defp login_token(url) do
    {body, 0} =
      System.cmd(
        "curl",
        curl_args(url, [
          "-H",
          "Content-Type: application/json",
          "-d",
          @default_admin,
          "#{url}/api/auth/login"
        ])
      )

    case Jason.decode(body) do
      {:ok, %{"token" => token}} -> token
      _ -> nil
    end
  end

  # The persistence witness, written: the marker website only exists
  # in data that survived the legs (the default admin row is re-seeded
  # by the first migration on an empty database and witnesses nothing).
  defp create_witness_website(url, token, marker) do
    {body, 0} =
      System.cmd(
        "curl",
        curl_args(url, [
          "-H",
          "authorization: Bearer #{token}",
          "-H",
          "Content-Type: application/json",
          "-d",
          Jason.encode!(%{name: marker, domain: "#{marker}.example"}),
          "-X",
          "POST",
          "#{url}/api/websites"
        ])
      )

    check(body =~ marker, "created the witness website #{marker} via the public API")
  end

  defp witness_website(url, token, marker, leg) do
    {body, 0} =
      System.cmd(
        "curl",
        curl_args(url, ["-H", "authorization: Bearer #{token}", "#{url}/api/websites"])
      )

    check(body =~ marker, "#{leg}: the witness website still answers — data rode the PVC")
  end

  # The first-run witness: upstream's default admin (the first-run
  # contract) signs in through the public API — it proves the auth
  # path and the bundled DB booted, NOT data survival (the first
  # migration re-seeds this row on an empty database; the legs'
  # persistence witness is the run-unique website).
  defp login(url) do
    args =
      curl_args(url, [
        "-o",
        "/dev/null",
        "-w",
        "%{http_code}",
        "-H",
        "Content-Type: application/json",
        "-d",
        @default_admin,
        "#{url}/api/auth/login"
      ])

    case System.cmd("curl", args) do
      {status, 0} -> {String.to_integer(status), ""}
      {_out, _code} -> {0, "curl exit"}
    end
  end

  defp kubectl(args, opts \\ []) do
    {out, code} = System.cmd("kubectl", ["--context", "k3d-fluxvale" | args])

    if code == 0 or opts[:best_effort] do
      String.trim(out)
    else
      raise "kubectl #{Enum.join(args, " ")} exited #{code}: #{out}"
    end
  end

  # --- transcript ------------------------------------------------------

  defp check(true, label), do: pass(label)
  defp check(false, label), do: fail(label)

  defp pass(label), do: IO.puts("PASS  #{label}")

  defp fail(label) do
    IO.puts("FAIL  #{label}")
    Process.put(:failures, Process.get(:failures, 0) + 1)
  end

  defp summarize do
    failures = Process.get(:failures, 0)

    if failures > 0 do
      IO.puts("FAIL  proof: #{failures} check(s) failed")
      System.halt(1)
    else
      IO.puts("PASS  proof: all checks passed")
      System.halt(0)
    end
  end
end

UmamiBundledLocalProof.main(System.argv())
