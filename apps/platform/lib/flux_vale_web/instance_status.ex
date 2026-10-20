defmodule FluxValeWeb.InstanceStatus do
  @moduledoc """
  The user-facing status vocabulary (#179): friendly labels and
  plain-language copy for every Instance state. Users never see
  Kubernetes internals — no namespaces, no RBAC wording, no raw
  operator messages — so this module owns the *entire* translation
  from internal state to rendered words:

  - the provisioning arc reads `submitted → provisioning → starting →
    running` (issue copy), mapped off the state machine's atoms
  - failures map through the row's `failure_reason` classification to
    a friendly message with a next step; the technical `status_message`
    stays on the DB row and renders only in the admin-only reveal
  - a provision that lingers past the slow threshold swaps in
    "taking longer than usual" copy while the state machine still says
    in-flight

  Denylist-enforced (test/support/no_k8s_leaks.ex): no term here may
  name the platform under the hood.
  """

  alias FluxVale.Infrastructure.Instance

  @labels %{
    pending: "Submitted",
    deploying: "Provisioning",
    starting: "Starting",
    running: "Running",
    stopped: "Stopped",
    error: "Failed",
    deleting: "Deleting"
  }

  @progress_copy %{
    pending: "We've got your request — setup will begin shortly.",
    deploying: "Setting up your app.",
    starting: "Starting it up.",
    running: "Your app is up and running.",
    stopped: "Your app is stopped. Your data is kept safe — start it again anytime.",
    deleting: "Cleaning up your app and its data."
  }

  # One friendly message per failure_reason, each with a next step;
  # nil (legacy rows written before #179) reads as the generic snag.
  @failure_copy %{
    deploy_failed:
      "We hit a snag setting up your app. Try again in a minute — if it keeps failing, we're already on it.",
    rollout_failed:
      "Your app didn't start up properly. Try again — if it keeps failing, we're on it.",
    stuck: "Setup took too long, so we stopped it. You can try again.",
    missing: "Your app went missing on our side. Try setting it up again.",
    start_failed: "We couldn't start your app. Try again in a minute.",
    stop_failed: "We couldn't stop your app. Try again in a minute.",
    teardown_failed:
      "We couldn't finish deleting your app. Try the delete again — it's safe to retry."
  }

  @generic_failure_copy "Something went wrong on our side. Try again — if it keeps happening, we're on it."

  @slow_copy "This is taking longer than usual — we're still working on it."

  @doc "The badge label for a state-machine status (#179's arc vocabulary)."
  @spec label(atom()) :: String.t()
  def label(status), do: Map.fetch!(@labels, status)

  @doc """
  The plain-language copy for an Instance's current state: progress
  copy on the way up, the friendly failure message (with a next step)
  on `:error`, and the taking-longer variant when a provision has
  lingered past the slow threshold.
  """
  @spec message(Instance.t()) :: String.t()
  def message(%Instance{status: :error, failure_reason: failure_reason}) do
    Map.get(@failure_copy, failure_reason, @generic_failure_copy)
  end

  def message(%Instance{status: status} = instance) when status in [:deploying, :starting] do
    if slow?(instance), do: @slow_copy, else: Map.fetch!(@progress_copy, status)
  end

  def message(%Instance{status: status}), do: Map.fetch!(@progress_copy, status)

  @doc "True while the state machine is mid-provision (spinner states)."
  @spec in_progress?(atom()) :: boolean()
  def in_progress?(status), do: status in [:deploying, :starting]

  @doc """
  Seconds a provision may linger in-flight before the taking-longer
  copy swaps in. Also the status-tick interval the LiveViews use to
  re-render an open page — a lingering provision writes nothing (a
  reconcile no-op doesn't broadcast), so only a tick moves the clock.
  """
  @spec slow_after_seconds() :: pos_integer()
  def slow_after_seconds do
    Application.get_env(:flux_vale, :provisioning_slow_seconds, 90)
  end

  # The slow clock starts at the provision's beginning: `deployed_at`
  # on a deploy, `updated_at` for a start (the last status write — the
  # start itself). Any state change resets the clock by construction.
  defp slow?(%Instance{} = instance) do
    clock = instance.deployed_at || instance.updated_at

    DateTime.diff(DateTime.utc_now(), clock, :second) > slow_after_seconds()
  end
end
