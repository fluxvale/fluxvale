# Local halves of the private-access exit proof (#273, ADR-0039 §6).
#
# Run from apps/platform: MIX_ENV=dev mix run ../../scripts/private-access-local-proof.exs <action> <state.json> <kubeconfig>
#
# The shell driver (scripts/private-access-local-proof.sh) owns preflight,
# HTTP probes and cleanup; this companion owns the DB and cluster-side
# halves, printing PASS/FAIL per check and halting non-zero on failure.
#
# Why a temp kubeconfig on the Cluster row: the platform's own provider
# reads the row's `kubeconfig_ref` (`K8s.kubeconfig/1`), and a host-run
# `mix run` has no in-cluster service account. The shell writes a real
# `kubectl config view --raw` file and this script points the row at it
# for the cluster-side halves. The original value is restored in cleanup.
#
# The instance is Ash.Seed-seeded rather than action-created: the create
# action enqueues the real deploy trigger, which would mint a catalog
# Deployment and race this proof's pause Deployment. Seeding is the
# documented way to produce a precondition actions can't produce without
# their side effects (apps/platform/AGENTS.md); the status transitions
# after it still run through InstanceK8s.update_status, the code's own
# funnel.

defmodule PrivateAccessLocalProof do
  alias FluxVale.Accounts
  alias FluxVale.Billing
  alias FluxVale.Catalog.AppVersion
  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.Namespace
  alias FluxVale.Clients.K8s.Resources.RoleBinding
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Infrastructure
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessProvider
  alias FluxVale.Infrastructure.Cluster
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Instance.StatusTransition
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.Identity.User

  require Ash.Query

  @namespace_prefix "fv273-proof"
  @tailnet_domain "local-proof.ts.net"
  @pause_image "rancher/mirrored-pause:3.6"
  @proof_label "fv273-private-access-proof"

  # ------------------------------------------------------------------
  # Entry
  # ------------------------------------------------------------------

  def main(argv) do
    # Dev's logger is :debug; the proof transcript is the deliverable,
    # so keep Ecto/HTTP query noise out of it unless something warns.
    Logger.configure(level: :warning)
    {action, state_path, kubeconfig_path} = parse_args(argv)
    Process.put(:failures, 0)

    try do
      apply(__MODULE__, String.to_existing_atom(action), [state_path, kubeconfig_path])
    rescue
      error ->
        fail("#{action} crashed: #{Exception.message(error)}")
        IO.puts(Exception.format(:error, error, __STACKTRACE__))
    end

    failures = Process.get(:failures, 0)

    if failures > 0 do
      IO.puts("FAIL  #{action}: #{failures} check(s) failed")
      System.halt(1)
    else
      IO.puts("PASS  #{action}: all checks passed")
      System.halt(0)
    end
  end

  defp parse_args([action, state_path, kubeconfig_path]),
    do: {action, state_path, kubeconfig_path}

  defp parse_args(_other) do
    IO.puts("usage: mix run private-access-local-proof.exs <action> <state.json> <kubeconfig>")
    System.halt(2)
  end

  # ------------------------------------------------------------------
  # seed
  # ------------------------------------------------------------------

  def seed(state_path, kubeconfig_path) do
    cluster = Cluster.get_by_name!("local", authorize?: false)
    previous_state = read_state(state_path)

    previous =
      case previous_state do
        nil -> cluster.kubeconfig_ref
        state -> Map.get(state, "original_kubeconfig_ref", cluster.kubeconfig_ref)
      end

    # A stale state file means a previous run crashed after seeding.
    # Clean its rows/namespace before minting the next proof's names, or
    # the old instance row would outlive the state that points at it.
    if previous_state do
      cleanup_stale_run!(cluster, previous_state, kubeconfig_path)
    end

    suffix = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    namespace = "#{@namespace_prefix}-#{suffix}"

    state = %{
      "suffix" => suffix,
      "namespace" => namespace,
      "cluster_id" => cluster.id,
      "original_kubeconfig_ref" => previous,
      "kubeconfig_path" => Path.expand(kubeconfig_path)
    }

    write_state(state_path, state)

    check("Cluster row points at the temp kubeconfig", fn ->
      set_cluster_ref!(cluster, Path.expand(kubeconfig_path))
      {:ok, Path.expand(kubeconfig_path)}
    end)

    admin = User.get_by_email!("admin@fluxvale.com", authorize?: false)

    org =
      case Accounts.personal_org_for_user(admin.id, authorize?: false) do
        {:ok, org} -> org
        :none -> raise "seed admin has no personal org — run `mix setup` first"
      end

    check("funded org (idempotent credit)", fn ->
      # Keyless grant would double-post on a rerun; the purchase-style
      # credit with a stable idempotency key replays to the same ledger
      # row instead, which is what "seed idempotently" means here.
      case Billing.credit_wallet(org, 200, idempotency_key: "fv273-private-access-proof:funding") do
        {:ok, entry} -> {:ok, "ledger entry #{entry.id}"}
        {:error, reason} -> {:fail, "credit failed: #{inspect(reason)}"}
      end
    end)

    refute_existing_gateway!(org, state_path)
    gateway = create_gateway!(org)
    # State before activate: a crash between create and activate must still
    # leave the run's own gateway id on disk, so the next run can tear it
    # down instead of refusing an "unreferenced" row.
    write_state(state_path, Map.merge(state, gateway_state(gateway)))
    gateway = activate_gateway!(gateway)

    version = catalog_version!()
    kubeconfig = kubeconfig!(kubeconfig_path)

    check("proof namespace exists", fn ->
      ensure_namespace!(kubeconfig, namespace)
      {:ok, namespace}
    end)

    check("pause Deployment exists in the proof namespace", fn ->
      apply_pause_deployment!(kubeconfig, namespace)
      {:ok, "app replicas=1 (#{@pause_image})"}
    end)

    check("platform RoleBinding exists in the proof namespace", fn ->
      rbac = Application.fetch_env!(:flux_vale, :instance_rbac)

      case RoleBinding.create(kubeconfig, namespace, rbac[:workload_role], %{
             service_account: rbac[:service_account],
             service_account_namespace: rbac[:service_account_namespace],
             role: rbac[:workload_role]
           }) do
        {:ok, _binding} -> {:ok, rbac[:workload_role]}
        {:error, reason} -> {:fail, inspect(reason)}
      end
    end)

    instance = seed_instance!(org, cluster, version, namespace, suffix)
    instance = walk_to!(instance, :running)
    write_state(state_path, Map.merge(read_state(state_path), %{"instance_id" => instance.id}))

    check("private instance is :running", fn ->
      {:ok, "#{instance.id} status=#{instance.status} exposure=#{instance.exposure}"}
    end)

    check("instance attached to the gateway (AccessRoute)", fn ->
      case Infrastructure.attach_instance(gateway, instance, authorize?: false) do
        {:ok, route} ->
          write_state(
            state_path,
            Map.merge(read_state(state_path), %{"route_key" => route.route_key})
          )

          {:ok, "route_key=#{route.route_key}"}

        {:error, reason} ->
          {:fail, inspect(reason)}
      end
    end)

    check("instance sleeps and the serve config is regenerated", fn ->
      sleeping = walk_to!(instance, :sleeping)
      scale!(kubeconfig, namespace, 0)
      refresh!(gateway)
      {:ok, "status=#{sleeping.status} replicas=0"}
    end)
  end

  # ------------------------------------------------------------------
  # part_a — the serve table
  # ------------------------------------------------------------------

  def part_a(state_path, _kubeconfig_path) do
    state = load_state!(state_path)
    gateway = gateway!(state)
    instance = instance!(state)
    kubeconfig = kubeconfig!(state["kubeconfig_path"])
    secret_name = serve_secret_name(gateway)
    expected_sleep_target = "/internal/access/#{gateway.id}/#{instance.id}"
    expected_awake_target = "http://app.#{instance.namespace}.svc.cluster.local:80"

    check("regenerate serve config with the instance :sleeping", fn ->
      refresh!(gateway)
      {:ok, "#{secret_name} written"}
    end)

    check("sleeping target is the platform wake endpoint", fn ->
      with {:ok, config} <- read_serve_config(kubeconfig, secret_name),
           {:ok, target} <- serve_target(config, state["route_key"]) do
        if String.contains?(target, expected_sleep_target) do
          {:ok, target}
        else
          {:fail, "expected #{expected_sleep_target} in #{target}"}
        end
      else
        {:error, reason} -> {:fail, inspect(reason)}
      end
    end)

    check("TCP arm carries the route port as HTTPS", fn ->
      with {:ok, config} <- read_serve_config(kubeconfig, secret_name) do
        if get_in(config, ["TCP", state["route_key"], "HTTPS"]) == true do
          {:ok, "TCP/#{state["route_key"]} HTTPS=true"}
        else
          {:fail, inspect(config["TCP"])}
        end
      end
    end)

    check("wake flips the instance :running through the status funnel", fn ->
      _starting = walk_to!(instance, :running)
      scale!(kubeconfig, instance.namespace, 1)
      {:ok, "status=running replicas=1"}
    end)

    check("regenerate serve config with the instance :running", fn ->
      refresh!(gateway)
      {:ok, "#{secret_name} rewritten"}
    end)

    check("running target is the instance Service", fn ->
      with {:ok, config} <- read_serve_config(kubeconfig, secret_name),
           {:ok, target} <- serve_target(config, state["route_key"]) do
        if target == expected_awake_target do
          {:ok, target}
        else
          {:fail, "expected #{expected_awake_target}, got #{target}"}
        end
      else
        {:error, reason} -> {:fail, inspect(reason)}
      end
    end)
  end

  # ------------------------------------------------------------------
  # reset — put the instance back to :sleeping for a capture / Part B
  # ------------------------------------------------------------------

  def reset(state_path, _kubeconfig_path) do
    state = load_state!(state_path)
    cluster = Ash.get!(Cluster, state["cluster_id"], authorize?: false)
    set_cluster_ref!(cluster, state["kubeconfig_path"])
    gateway = gateway!(state)
    instance = instance!(state)
    kubeconfig = kubeconfig!(state["kubeconfig_path"])

    check("instance reset to :sleeping", fn ->
      sleeping = walk_to!(instance, :sleeping)
      scale!(kubeconfig, sleeping.namespace, 0)
      refresh!(gateway)
      {:ok, "status=#{sleeping.status} replicas=0"}
    end)

    check("serve config points at the wake endpoint again", fn ->
      with {:ok, config} <- read_serve_config(kubeconfig, serve_secret_name(gateway)),
           {:ok, target} <- serve_target(config, state["route_key"]) do
        expected = "/internal/access/#{gateway.id}/#{instance.id}"

        if String.contains?(target, expected) do
          {:ok, target}
        else
          {:fail, "expected #{expected} in #{target}"}
        end
      else
        {:error, reason} -> {:fail, inspect(reason)}
      end
    end)
  end

  # ------------------------------------------------------------------
  # restore_cluster — let the in-pod platform reach the cluster for Part B
  # ------------------------------------------------------------------

  def restore_cluster(state_path, _kubeconfig_path) do
    state = load_state!(state_path)

    check("Cluster row restored for the in-pod endpoint", fn ->
      cluster = Ash.get!(Cluster, state["cluster_id"], authorize?: false)
      set_cluster_ref!(cluster, state["original_kubeconfig_ref"])
      {:ok, "kubeconfig_ref=#{inspect(state["original_kubeconfig_ref"])}"}
    end)
  end

  # ------------------------------------------------------------------
  # verify_wake — Part B's DB/cluster-side assertion
  # ------------------------------------------------------------------

  def verify_wake(state_path, _kubeconfig_path) do
    state = load_state!(state_path)
    instance = instance!(state)
    kubeconfig = kubeconfig!(state["kubeconfig_path"])

    check("instance left :sleeping OR Deployment replicas is 1", fn ->
      fresh = Instance.get_by_id!(instance.id, authorize?: false)
      replicas = deployment_replicas(kubeconfig, fresh.namespace)

      cond do
        fresh.status != :sleeping ->
          {:ok, "status=#{fresh.status} replicas=#{inspect(replicas)}"}

        replicas == 1 ->
          {:ok, "status=:sleeping but Deployment scaled to 1"}

        true ->
          {:fail, "status=#{fresh.status} replicas=#{inspect(replicas)}"}
      end
    end)

    check("wake markers were stamped", fn ->
      fresh = Instance.get_by_id!(instance.id, authorize?: false)

      if fresh.wake_requested_at || fresh.wake_promoted_at do
        {:ok,
         "requested=#{inspect(fresh.wake_requested_at)} promoted=#{inspect(fresh.wake_promoted_at)}"}
      else
        {:fail, "both wake markers are nil"}
      end
    end)
  end

  # ------------------------------------------------------------------
  # cleanup
  # ------------------------------------------------------------------

  # The shell's fallback deletes the gateway's named cluster objects
  # directly, then re-runs cleanup with FV273_FORCE_CLEANUP=1 so a row
  # whose detach limb lost its namespace can still be removed. Without
  # the env flag this never runs: a real teardown failure must stay
  # visible, with its objects intact.
  defp force_destroy_gateway(gateway, reason) do
    if System.get_env("FV273_FORCE_CLEANUP") == "1" do
      changeset =
        Ash.Changeset.for_destroy(gateway, :destroy_after_teardown, %{}, authorize?: false)

      case Ash.destroy(changeset) do
        :ok -> {:ok, "row hard-deleted after teardown failure (#{inspect(reason)})"}
        {:ok, _} -> {:ok, "row hard-deleted after teardown failure (#{inspect(reason)})"}
        {:error, destroy_reason} -> {:fail, inspect(destroy_reason)}
      end
    else
      {:fail, inspect(reason)}
    end
  end

  def cleanup(state_path, _kubeconfig_path) do
    state = read_state(state_path)

    if state do
      cluster = Ash.get!(Cluster, state["cluster_id"], authorize?: false)
      kubeconfig = kubeconfig!(state["kubeconfig_path"])

      check("Cluster row points at the temp kubeconfig for teardown", fn ->
        set_cluster_ref!(cluster, state["kubeconfig_path"])
        {:ok, state["kubeconfig_path"]}
      end)

      check("gateway torn down (cluster objects + row)", fn ->
        case Ash.get(AccessGateway, state["gateway_id"], authorize?: false) do
          {:ok, gateway} ->
            case Ash.update(
                   Ash.Changeset.for_update(gateway, :perform_teardown, %{}, authorize?: false)
                 ) do
              {:ok, _gone} ->
                {:ok, "gateway #{gateway.id} removed"}

              {:error, reason} ->
                force_destroy_gateway(gateway, reason)
            end

          {:error, _gone} ->
            {:ok, "row already absent"}
        end
      end)

      check("instance row removed", fn ->
        case Ash.get(Instance, state["instance_id"], authorize?: false) do
          {:ok, instance} ->
            case Ash.destroy(instance, authorize?: false) do
              :ok -> {:ok, "instance #{instance.id} removed"}
              {:ok, _} -> {:ok, "instance #{instance.id} removed"}
              {:error, reason} -> {:fail, inspect(reason)}
            end

          {:error, _gone} ->
            {:ok, "row already absent"}
        end
      end)

      check("proof namespace deleted", fn ->
        case Namespace.exists?(kubeconfig, state["namespace"]) do
          {:ok, false} ->
            {:ok, "absent"}

          {:ok, true} ->
            case Namespace.delete(kubeconfig, state["namespace"]) do
              :ok -> {:ok, "deletion initiated"}
              {:error, reason} -> {:fail, inspect(reason)}
            end

          {:error, reason} ->
            {:fail, inspect(reason)}
        end
      end)

      check("Cluster row restored", fn ->
        fresh = Ash.get!(Cluster, state["cluster_id"], authorize?: false)
        set_cluster_ref!(fresh, state["original_kubeconfig_ref"])

        restored = Ash.get!(Cluster, state["cluster_id"], authorize?: false)

        if restored.kubeconfig_ref == state["original_kubeconfig_ref"] do
          {:ok, "kubeconfig_ref=#{inspect(restored.kubeconfig_ref)}"}
        else
          {:fail, "still #{inspect(restored.kubeconfig_ref)}"}
        end
      end)
    else
      IO.puts("PASS  cleanup: no state file — nothing seeded by this run")
    end
  end

  # ------------------------------------------------------------------
  # Seeding helpers
  # ------------------------------------------------------------------

  defp cleanup_stale_run!(cluster, state, kubeconfig_path) do
    set_cluster_ref!(cluster, Path.expand(kubeconfig_path))
    kubeconfig = kubeconfig!(kubeconfig_path)

    if state["gateway_id"] do
      case Ash.get(AccessGateway, state["gateway_id"], authorize?: false) do
        {:ok, gateway} ->
          _ =
            Ash.update(
              Ash.Changeset.for_update(gateway, :perform_teardown, %{}, authorize?: false)
            )

        {:error, _gone} ->
          :ok
      end
    end

    if state["instance_id"] do
      case Ash.get(Instance, state["instance_id"], authorize?: false) do
        {:ok, instance} -> _ = Ash.destroy(instance, authorize?: false)
        {:error, _gone} -> :ok
      end
    end

    if state["namespace"] do
      _ = Namespace.delete(kubeconfig, state["namespace"])
    end

    :ok
  end

  defp refute_existing_gateway!(org, state_path) do
    case AccessGateway.get_for_organization(org.id, authorize?: false) do
      {:ok, gateway} ->
        state = read_state(state_path)

        if state && state["gateway_id"] == gateway.id do
          # A previous failed run left this run's own gateway. Tear it
          # down before minting a fresh one (idempotent rerun), by id.
          _ =
            Ash.update(
              Ash.Changeset.for_update(gateway, :perform_teardown, %{}, authorize?: false)
            )

          :ok
        else
          raise """
          The seed admin's org already has an access gateway (#{gateway.id}) that this
          proof did not create (no matching state file). Refusing to touch it. Remove it
          via the Access panel, or rerun after restoring the proof state file.
          """
        end

      {:error, _none} ->
        :ok
    end
  end

  defp create_gateway!(org) do
    gateway =
      AccessGateway.create!(
        %{
          organization_id: org.id,
          monthly_cents: 200,
          tailnet_domain: @tailnet_domain,
          auth_key: "tskey-local-proof-not-a-real-key"
        },
        authorize?: false
      )

    IO.puts("PASS  gateway row created (#{gateway.id}, #{gateway.hostname})")
    gateway
  end

  defp activate_gateway!(gateway) do
    now = DateTime.utc_now()

    gateway
    |> Ash.Changeset.for_update(
      :update_state,
      %{
        state: :active,
        status_message: "Connected",
        metering_since: now,
        provisioned_at: now
      },
      authorize?: false
    )
    |> Ash.update!()
    |> tap(fn active -> IO.puts("PASS  gateway row :active (#{active.hostname})") end)
  end

  defp gateway_state(gateway) do
    short = short_id(gateway.id)

    %{
      "gateway_id" => gateway.id,
      "gateway_hostname" => gateway.hostname,
      "tailnet_domain" => gateway.tailnet_domain,
      "serve_secret" => "serve-config-#{short}",
      "objects" => %{
        "deployment" => "gateway-#{short}",
        "serve_secret" => "serve-config-#{short}",
        "credential_secret" => "credential-#{short}",
        "api_credential_secret" => "api-credential-#{short}",
        "pvc" => "state-#{short}"
      }
    }
  end

  defp catalog_version! do
    case AppVersion
         |> Ash.Query.filter(not is_nil(image) and not is_nil(port))
         |> Ash.read_first(authorize?: false) do
      {:ok, %AppVersion{} = version} ->
        version

      _none ->
        raise "no catalog AppVersion with image+port in flux_vale_dev — run `mix setup` first"
    end
  end

  defp ensure_namespace!(kubeconfig, namespace) do
    case Namespace.exists?(kubeconfig, namespace) do
      {:ok, true} ->
        # A rerun's state should have removed it; a live one means stale
        # proof residue. Delete and wait so the apply is deterministic.
        _ = Namespace.delete(kubeconfig, namespace)
        wait_until(fn -> Namespace.exists?(kubeconfig, namespace) == {:ok, false} end, 60_000)
        create_namespace!(kubeconfig, namespace)

      {:ok, false} ->
        create_namespace!(kubeconfig, namespace)

      {:error, reason} ->
        raise "namespace check failed: #{inspect(reason)}"
    end
  end

  defp create_namespace!(kubeconfig, namespace) do
    labels = %{
      "app.kubernetes.io/part-of" => @proof_label,
      "app.kubernetes.io/managed-by" => "fluxvale"
    }

    case Namespace.create(kubeconfig, namespace, %{labels: labels}) do
      {:ok, _namespace} -> :ok
      {:error, reason} -> raise "namespace create failed: #{inspect(reason)}"
    end
  end

  defp apply_pause_deployment!(kubeconfig, namespace) do
    manifest = %{
      "apiVersion" => "apps/v1",
      "kind" => "Deployment",
      "metadata" => %{
        "name" => "app",
        "namespace" => namespace,
        "labels" => %{"app" => "app", "app.kubernetes.io/part-of" => @proof_label}
      },
      "spec" => %{
        "replicas" => 1,
        "selector" => %{"matchLabels" => %{"app" => "app"}},
        "template" => %{
          "metadata" => %{"labels" => %{"app" => "app"}},
          "spec" => %{
            "containers" => [
              %{
                "name" => "app",
                "image" => @pause_image,
                "command" => ["/pause"]
              }
            ]
          }
        }
      }
    }

    case Deployment.apply_manifest(kubeconfig, manifest) do
      {:ok, _deployment} -> :ok
      {:error, reason} -> raise "deployment apply failed: #{inspect(reason)}"
    end
  end

  defp seed_instance!(org, cluster, version, namespace, suffix) do
    attrs = %{
      name: "FV273 private proof app",
      slug: "fv273-proof-#{suffix}",
      namespace: namespace,
      status: :starting,
      exposure: :private,
      organization_id: org.id,
      cluster_id: cluster.id,
      app_version_id: version.id,
      size_id: version.recommended_size_id,
      image: version.image,
      port: version.port,
      cpu_cores: version.default_cpu_cores,
      memory_mb: version.default_memory_mb,
      storage_gb: version.default_storage_gb,
      deployed_at: DateTime.utc_now(),
      grandfathered_monthly_cents: 100,
      grandfathered_stopped_monthly_cents: 0
    }

    instance = Ash.Seed.seed!(Instance, attrs)
    IO.puts("PASS  instance row seeded (#{instance.id}, #{instance.namespace})")
    instance
  end

  # ------------------------------------------------------------------
  # Flow helpers
  # ------------------------------------------------------------------

  defp walk_to!(instance, target) do
    if instance.status == target do
      instance
    else
      case path_to(instance.status, target) do
        nil ->
          raise "no legal status path from #{instance.status} to #{target}"

        path ->
          Enum.reduce(path, instance, fn status, current ->
            {:ok, next} = InstanceK8s.update_status(current, status, nil)
            next
          end)
      end
    end
  end

  defp path_to(from, to), do: bfs([{from, []}], MapSet.new([from]), to)

  defp bfs([], _seen, _to), do: nil

  defp bfs([{to, path} | _queue], _seen, to), do: Enum.reverse(path)

  defp bfs([{node, path} | queue], seen, to) do
    edges = Map.get(StatusTransition.valid_transitions(), node, [])

    {queue, seen} =
      Enum.reduce(edges, {queue, seen}, fn next, {queue, seen} ->
        if MapSet.member?(seen, next) do
          {queue, seen}
        else
          {queue ++ [{next, [next | path]}], MapSet.put(seen, next)}
        end
      end)

    bfs(queue, seen, to)
  end

  defp refresh!(gateway) do
    case AccessProvider.impl_for(gateway).refresh_routes(gateway) do
      {:ok, _secret} -> :ok
      {:error, reason} -> raise "serve-config refresh failed: #{inspect(reason)}"
    end
  end

  defp scale!(kubeconfig, namespace, replicas) do
    case Deployment.scale(kubeconfig, namespace, "app", replicas) do
      {:ok, _deployment} -> :ok
      {:error, reason} -> raise "Deployment scale failed: #{inspect(reason)}"
    end
  end

  defp deployment_replicas(kubeconfig, namespace) do
    case Deployment.get(kubeconfig, namespace, "app") do
      {:ok, deployment} -> get_in(deployment, ["spec", "replicas"])
      {:error, _reason} -> nil
    end
  end

  defp read_serve_config(kubeconfig, secret_name) do
    with {:ok, data} <- Secret.get_data(kubeconfig, "fluxvale-access", secret_name),
         json when is_binary(json) <- data["serve.json"] do
      {:ok, Jason.decode!(json)}
    else
      {:error, reason} -> {:error, reason}
      _missing -> {:error, :serve_json_missing}
    end
  end

  defp serve_target(config, route_key) do
    prefix = ":#{route_key}"

    targets =
      for {key, %{"Handlers" => %{"/" => %{"Proxy" => target}}}} <- config["Web"] || %{},
          String.ends_with?(key, prefix),
          do: target

    case targets do
      [target] -> {:ok, target}
      other -> {:error, {:expected_one_target, other}}
    end
  end

  # ------------------------------------------------------------------
  # Cluster row + record helpers
  # ------------------------------------------------------------------

  defp set_cluster_ref!(cluster, ref) do
    cluster
    |> Ash.Changeset.for_update(:update, %{kubeconfig_ref: ref}, authorize?: false)
    |> Ash.update!()
  end

  defp kubeconfig!(path) do
    case K8s.kubeconfig(path) do
      {:ok, kubeconfig} -> kubeconfig
      {:error, reason} -> raise "kubeconfig load failed (#{path}): #{inspect(reason)}"
    end
  end

  defp gateway!(state), do: AccessGateway.get_by_id!(state["gateway_id"], authorize?: false)
  defp instance!(state), do: Instance.get_by_id!(state["instance_id"], authorize?: false)

  defp serve_secret_name(gateway), do: "serve-config-#{short_id(gateway.id)}"

  defp short_id(id) do
    id
    |> to_string()
    |> String.replace("-", "")
    |> String.slice(-10, 10)
  end

  defp wait_until(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        raise "timed out waiting for cluster state"
      else
        Process.sleep(500)
        do_wait(fun, deadline)
      end
    end
  end

  # ------------------------------------------------------------------
  # State file
  # ------------------------------------------------------------------

  defp read_state(path) do
    case File.read(path) do
      {:ok, body} -> Jason.decode!(body)
      {:error, :enoent} -> nil
      {:error, reason} -> raise "state read failed: #{inspect(reason)}"
    end
  end

  defp load_state!(path) do
    read_state(path) || raise "no proof state at #{path} — run seed first"
  end

  defp write_state(path, state) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(state, pretty: true))
  end

  # ------------------------------------------------------------------
  # PASS/FAIL
  # ------------------------------------------------------------------

  defp check(name, fun) do
    outcome =
      try do
        fun.()
      rescue
        error -> {:fail, "crashed: #{Exception.message(error)}"}
      end

    case outcome do
      :ok ->
        pass(name)

      {:ok, detail} ->
        pass("#{name} — #{detail}")

      {:fail, detail} ->
        fail("#{name} — #{detail}")
    end
  end

  defp pass(message), do: IO.puts("PASS  #{message}")

  defp fail(message) do
    IO.puts("FAIL  #{message}")
    Process.put(:failures, Process.get(:failures, 0) + 1)
  end
end

PrivateAccessLocalProof.main(System.argv())
