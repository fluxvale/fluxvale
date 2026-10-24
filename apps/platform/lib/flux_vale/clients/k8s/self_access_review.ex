defmodule FluxVale.Clients.K8s.SelfAccessReview do
  @moduledoc """
  SelfSubjectAccessReview probe: asks the API server's authorizer whether
  the caller currently holds a verb — evaluated against the same
  informer-backed RBAC view that will authorize the real request.

  That shared view is the point (#238): a RoleBinding created moments
  ago authorizes nothing until the API server's RBAC cache ingests it,
  so polling this review waits for the cache itself, not for a guess at
  its latency. True per-apiserver (single-node k3d included — the only
  control plane today); an HA pair could still split one poll from the
  next apply across members, and the caller's bounded retry then lands
  the same error it would have without the wait. `wait_until_allowed/5`
  polls until the verb is visible or the deadline passes (propagation
  on a loaded single-node cluster is normally tens of ms, occasionally
  seconds).
  """

  alias FluxVale.Clients.K8s.Error

  require Logger

  @default_poll_ms 100
  @default_timeout_ms 5_000

  @doc """
  Polls `can_i?` for `verb` on `resource` in `namespace` until allowed.

  Returns `:ok`, or `{:error, %Error{reason: :timeout}}` when the
  deadline passes first — deliberately not a failure verdict: callers
  proceed and let the real request produce ground truth (a genuinely
  missing grant reports the API server's verbatim message, which is
  worth more than our timeout).
  """
  @spec wait_until_allowed(Kubereq.Kubeconfig.t(), String.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, Error.t()}
  def wait_until_allowed(kubeconfig, namespace, resource, verb, opts \\ []) do
    poll_ms = Keyword.get(opts, :poll_ms, @default_poll_ms)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    poll(kubeconfig, namespace, resource, verb, poll_ms, deadline)
  end

  defp poll(kubeconfig, namespace, resource, verb, poll_ms, deadline) do
    if allowed?(kubeconfig, namespace, resource, verb) do
      :ok
    else
      now_ms = System.monotonic_time(:millisecond)
      remaining_ms = deadline - now_ms

      if remaining_ms <= 0 do
        Logger.warning(
          "RBAC propagation wait timed out: #{verb} on #{resource} in #{namespace} still denied"
        )

        {:error, Error.timeout("RBAC propagation wait timed out for #{verb} on #{resource}")}
      else
        sleep_ms = min(poll_ms, remaining_ms)
        Process.sleep(sleep_ms)
        poll(kubeconfig, namespace, resource, verb, poll_ms, deadline)
      end
    end
  end

  # can_i? returns false on request failures, but attach itself raises
  # on a broken kubeconfig — a probe must never take the deploy down
  # with it (the trigger's {:ok, either-way} contract), so any raise
  # reads as "not visible yet" and the deadline still bounds the wait.
  defp allowed?(kubeconfig, namespace, resource, verb) do
    req = create_req(kubeconfig)

    Kubereq.can_i?(req, verb: verb, version: "v1", resource: resource, namespace: namespace)
  rescue
    _raise -> false
  end

  # can_i? builds the review manifest itself (apiVersion/kind included)
  # and do_create re-derives the request's surface from it, so the
  # attach carries only the kubeconfig — the api_version/kind here
  # mirror the review's surface for the reader, they route nothing.
  defp create_req(kubeconfig) do
    Kubereq.attach(Req.new(),
      kubeconfig: kubeconfig,
      api_version: "authorization.k8s.io/v1",
      kind: "SelfSubjectAccessReview"
    )
  end
end
