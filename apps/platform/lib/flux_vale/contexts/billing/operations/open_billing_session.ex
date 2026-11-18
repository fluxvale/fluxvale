defmodule FluxVale.Billing.Operations.OpenBillingSession do
  @moduledoc """
  The "Add payment method" click's seam (#829 S5): resolve the
  billing-session request from our own rows, open the provider's
  pre-authenticated portal, persist the returned customer reference,
  and hand back the ONE-TIME portal URL.

  The request is resolved HERE, not in the LiveView — the domain is
  the public seam and the page never calls the provider module
  directly. The org's id rides as the provider-side external_id; the
  email is the enabling OWNER'S primary verified address (the sweep's
  member→address resolution, duplicated per the operation-boundary
  rule — private helpers are owned, not shared); `name` is nil (User
  carries username only today — a display name would ride here); the
  billing address is the SETTING'S saved evidence, country required
  (the card disables the button without it, and a crafted click still
  refuses here — Polar computes tax from it).

  The customer reference persists through `:set_method_status` — a
  NEWLY linked customer (or a changed reference) reads `:none` until the
  mount sync sees a method; a re-opened portal for the SAME customer
  preserves `:attached` (the provider has not reported removal — the
  sync, not a re-open, owns that flip). The portal URL is returned,
  NEVER stored — every click mints a fresh session (the plan's
  never-stored rule).

  The seam enforces its own preconditions: gate-on only (the launch
  posture makes no charge-lane traffic), OWNER-role only (recurring
  spend consent rides the same ownership notion the write policy uses —
  defense-in-depth behind the LiveView's button gate), the owner's
  verified address present, the evidence country present.
  """

  alias FluxVale.Accounts.Organization
  alias FluxVale.Billing
  alias FluxVale.Billing.AutoRechargeSetting
  alias FluxVale.Checks.ActorIsOrganizationOwner
  alias FluxVale.Identity.User
  alias FluxVale.Identity.UserEmail

  require Ash.Query

  @spec call(Organization.t(), AutoRechargeSetting.t(), User.t()) ::
          {:ok, String.t()} | {:error, term()}
  def call(org, setting, owner) do
    cond do
      # The gate guard is the seam's own: a LiveView guard miss must
      # still answer refusal, never a provider call.
      not Billing.auto_recharge_charge_mode?() ->
        {:error, :charge_mode_off}

      # Recurring-spend consent is owner-role (decision C) — the seam
      # does not trust its caller's button gate.
      not ActorIsOrganizationOwner.owner?(owner.id, org.id) ->
        {:error, :not_owner}

      true ->
        open(org, setting, owner)
    end
  end

  defp open(org, setting, owner) do
    with {:ok, email} <- owner_email(owner.id),
         {:ok, customer_id, portal_url} <- create_session(org, setting, email) do
      # The status stays :none until the sync sees a method — persisting
      # the customer reference only. System write (actor-forbidden by
      # policy), authorize?: false.
      case persist_reference(setting, customer_id) do
        {:ok, _updated} -> {:ok, portal_url}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp create_session(org, setting, email) do
    with {:ok, country} <- billing_country(setting) do
      request = %{
        organization_id: org.id,
        email: email,
        name: nil,
        billing_address: %{country: country, state: setting.billing_state}
      }

      provider = Application.fetch_env!(:flux_vale, :payments_provider)

      case provider.create_billing_session(request, []) do
        {:ok, %{customer_id: customer_id, portal_url: portal_url}} ->
          {:ok, customer_id, portal_url}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # The evidence is the SETTING'S (decision C — owner-set, sensitive):
  # an empty country cannot reach the provider (it taxes against the
  # address), so the click refuses and the card's hint points at the
  # charge settings.
  defp billing_country(setting) do
    case setting.billing_country do
      country when is_binary(country) and country != "" -> {:ok, country}
      _missing -> {:error, :billing_country_missing}
    end
  end

  # The owner's primary VERIFIED address (#285 T3): the sweep's
  # resolution, duplicated per the operation-boundary rule. An owner
  # without one (data drift — actions always stamp the primary) has no
  # customer identity to upsert with, so the click refuses.
  defp owner_email(owner_id) do
    found =
      UserEmail
      |> Ash.Query.filter(user_id == ^owner_id and is_primary and not is_nil(verified_at))
      |> Ash.read_one!(authorize?: false)

    case found do
      %{address: address} -> {:ok, to_string(address)}
      nil -> {:error, :owner_email_missing}
    end
  end

  defp persist_reference(setting, customer_id) do
    # A re-opened portal for the SAME customer must not reset the
    # status — the provider has not reported removal; `:none` is only
    # for a newly linked customer (or a changed reference), and the
    # mount sync owns every later flip.
    status =
      if setting.payment_method_status == :attached and
           setting.provider_customer_id == customer_id do
        :attached
      else
        :none
      end

    setting
    |> Ash.Changeset.for_update(:set_method_status, %{
      payment_method_status: status,
      provider_customer_id: customer_id
    })
    |> Ash.update(authorize?: false)
  end
end
