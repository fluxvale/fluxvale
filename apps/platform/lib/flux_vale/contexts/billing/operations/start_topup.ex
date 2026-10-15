defmodule FluxVale.Billing.Operations.StartTopup do
  @moduledoc """
  Opens a top-up: creates the pending `Topup` row, then the gateway
  checkout through the active provider
  (`config :flux_vale, :payments_provider`, ADR-0029), attaching the
  returned payment-request id. The row is the webhook's join key —
  `reference_number` carries the top-up id so the gateway payload
  echoes it too (the webhook heals the window where attach itself
  failed, by reference).

  Checkout failure marks the row `:failed` (terminal, auditable) and
  returns the error; the buyer retries with a fresh row. System
  operation, `authorize?: false` — the row is created from a flow that
  already established org membership through the actor's policy-checked
  reads, mirroring the wallet seam.
  """

  alias FluxVale.Accounts.Organization
  alias FluxVale.Billing.Topup

  @currency "USD"

  @type params :: %{
          required(:amount_cents) => pos_integer(),
          required(:redirect_url) => String.t(),
          optional(:buyer_email) => String.t() | nil,
          optional(:buyer_name) => String.t() | nil,
          optional(:billing_country) => String.t() | nil,
          optional(:tax_rate_bp) => non_neg_integer()
        }

  @spec call(Organization.t(), params(), keyword()) ::
          {:ok, Topup.t(), String.t()} | {:error, term()}
  def call(%Organization{} = org, params, opts \\ []) do
    with {:ok, topup} <- create_topup(org, params) do
      provider = Application.fetch_env!(:flux_vale, :payments_provider)

      request = %{
        amount_cents: topup.amount_cents,
        currency: @currency,
        reference: topup.id,
        redirect_url: params.redirect_url,
        email: topup.buyer_email,
        name: topup.buyer_name
      }

      result = provider.create_checkout(request, Keyword.get(opts, :provider_opts, []))

      case result do
        {:ok, %{payment_request_id: request_id, checkout_url: url}} ->
          attach(topup, request_id, url)

        {:error, reason} ->
          fail_silently(topup)
          {:error, reason}
      end
    end
  end

  defp create_topup(org, params) do
    Topup.create(
      %{
        organization_id: org.id,
        amount_cents: params.amount_cents,
        buyer_email: params[:buyer_email],
        buyer_name: params[:buyer_name],
        billing_country: params[:billing_country],
        tax_rate_bp: params[:tax_rate_bp] || 0
      },
      authorize?: false
    )
  end

  defp attach(topup, request_id, url) do
    case Topup.attach_checkout(topup, %{payment_request_id: request_id}, authorize?: false) do
      {:ok, attached} -> {:ok, attached, url}
      {:error, reason} -> {:error, reason}
    end
  end

  # The checkout never opened — the row stays as a failed-attempt record
  # for the org's history; a DB hiccup here loses only the marker.
  defp fail_silently(topup) do
    _result = Topup.mark_failed(topup, %{}, authorize?: false)
    :ok
  end
end
