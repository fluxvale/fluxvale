defmodule FluxVale.Billing.Operations.StartTopup do
  @moduledoc """
  Opens a top-up: creates the pending `Topup` row, then the gateway
  checkout through the active provider
  (`config :flux_vale, :payments_provider`, ADR-0029), attaching the
  returned payment-request id. The row is the webhook's join key —
  `reference_number` carries the top-up id so the gateway payload
  echoes it too (the webhook heals the window where attach itself
  failed, by reference).

  Credits are a single-purpose voucher — VAT added on top (#138,
  ADR-0029 Am. 3 gate 2): the row's `amount_cents` is the NET credit,
  `tax_cents` the VAT on it (the caller's figure, or
  `FluxVale.Billing.Tax.tax_cents/2` from `tax_rate_bp` when absent —
  one formula, never inlined twice), and the gateway is charged the
  GROSS. `reverse_charge?` and `location_verified?` are derived here
  from the caller's evidence (`FluxVale.Billing.Tax`), so the recorded
  proofs cannot fork from the buyer input.

  Checkout failure marks the row `:failed` (terminal, auditable) and
  returns the error; the buyer retries with a fresh row. System
  operation, `authorize?: false` — the row is created from a flow that
  already established org membership through the actor's policy-checked
  reads, mirroring the wallet seam.
  """

  alias FluxVale.Accounts.Organization
  alias FluxVale.Billing.Tax
  alias FluxVale.Billing.Topup

  @currency "USD"

  @type params :: %{
          required(:amount_cents) => pos_integer(),
          required(:redirect_url) => String.t(),
          optional(:buyer_email) => String.t() | nil,
          optional(:buyer_name) => String.t() | nil,
          optional(:billing_country) => String.t() | nil,
          optional(:billing_state) => String.t() | nil,
          optional(:customer_type) => :consumer | :business,
          optional(:vat_number) => String.t() | nil,
          optional(:ip_country) => String.t() | nil,
          optional(:tax_rate_bp) => non_neg_integer(),
          optional(:tax_cents) => non_neg_integer()
        }

  @spec call(Organization.t(), params(), keyword()) ::
          {:ok, Topup.t(), String.t()} | {:error, term()}
  def call(%Organization{} = org, params, opts \\ []) do
    with {:ok, topup} <- create_topup(org, params) do
      provider = Application.fetch_env!(:flux_vale, :payments_provider)

      request = %{
        # The gateway charges the gross — net credit + VAT (#138).
        amount_cents: topup.amount_cents + topup.tax_cents,
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
    customer_type = params[:customer_type] || :consumer
    reverse_charge? = Tax.reverse_charge?(customer_type, params[:vat_number])

    # Reverse charge: the applied rate is 0 and tax is 0 — enforced here
    # so the row can never contradict the proof it records (the wizard
    # resolves the rate the same way for its display).
    rate_bp = if reverse_charge?, do: 0, else: params[:tax_rate_bp] || 0

    tax_cents =
      if reverse_charge?,
        do: 0,
        else: params[:tax_cents] || Tax.tax_cents(params.amount_cents, rate_bp)

    Topup.create(
      %{
        organization_id: org.id,
        amount_cents: params.amount_cents,
        buyer_email: params[:buyer_email],
        buyer_name: params[:buyer_name],
        billing_country: params[:billing_country],
        billing_state: params[:billing_state],
        customer_type: customer_type,
        vat_number: params[:vat_number],
        ip_country: params[:ip_country],
        tax_rate_bp: rate_bp,
        tax_cents: tax_cents,
        reverse_charge?: reverse_charge?,
        location_verified?: Tax.location_verified?(params[:billing_country], params[:ip_country])
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
