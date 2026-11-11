defmodule FluxVale.Infrastructure.Operations.WakeInstance do
  @moduledoc """
  The traffic-reverse of sleep (#203, ADR-0036): an anonymous visitor
  wakes a sleeping instance through the edge — `start` with the same
  funded-wallet gate a member's Start would run.

  The edge has no actor, so the action can't run its policy — the
  `ActorOrgWalletFunded` check's own predicate decides here (policy and
  plug-land share the module; this is the third sharer, by design).
  An unfunded org's sleeping instance stays asleep: waking it would
  only re-enter the #124 ladder's stop arm a minute later.
  """

  alias FluxVale.Checks.ActorOrgWalletFunded
  alias FluxVale.Infrastructure.Instance

  require Logger

  @doc """
  Wakes a `:sleeping` instance (`{:ok, instance}` — `:starting` on
  success), or `{:error, :unfunded}`. Any other status is a no-op
  `{:ok, instance}`: the caller answers from the status it sees.
  """
  @spec call(Instance.t()) :: {:ok, Instance.t()} | {:error, :unfunded}
  def call(%{status: :sleeping} = instance) do
    if ActorOrgWalletFunded.org_funded?(instance.organization_id) do
      # authorize?: false with the funded gate run explicitly above —
      # the action's own ActorOrgWalletFunded policy is what this
      # replaces for the actorless edge path (the ladder's posture).
      started = Instance.start(instance, authorize?: false)

      capture_wake(started)
    else
      {:error, :unfunded}
    end
  end

  def call(instance), do: {:ok, instance}

  # ADR-0049 S1b: fired only where the wake TOOK (`:starting` — a
  # failed scale lands `:error`, which is not a wake). The edge wake is
  # anonymous: the visitor carries no user id, so the event rides nil.
  defp capture_wake({:ok, %{status: :starting} = instance}) do
    case app_slug(instance) do
      # The slug is unreadable — the #232 wake-metric posture:
      # analytics must never fail a request that already succeeded.
      nil ->
        :ok

      app_slug ->
        FluxVale.Analytics.capture("instance wake triggered", nil, %{app_slug: app_slug})

        :ok
    end

    {:ok, instance}
  end

  # A failed scale (the instance landed `:error`) or a propagated
  # error — not a wake; the caller answers from what it sees.
  defp capture_wake({:ok, instance}), do: {:ok, instance}

  defp capture_wake({:error, _reason} = error), do: error

  # The catalog slug — the #232 wake-metric label's value, resolved
  # fresh per emission. Guarded the same way: an unreadable slug skips
  # the event with a log instead of failing the wake.
  defp app_slug(instance) do
    loaded = Ash.load!(instance, [app_version: :app], authorize?: false)
    loaded.app_version.app.slug
  rescue
    # coveralls-ignore-start - defensive: the relationships are
    # FK-protected, so this arm guards only freak failures — the same
    # unreachable class the wake metric's own helper documents.
    error ->
      Logger.warning("wake event skipped: app slug unreadable (#{inspect(error)})")

      nil
      # coveralls-ignore-stop
  end
end
