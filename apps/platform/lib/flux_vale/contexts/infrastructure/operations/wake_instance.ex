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
      Instance.start(instance, authorize?: false)
    else
      {:error, :unfunded}
    end
  end

  def call(instance), do: {:ok, instance}
end
