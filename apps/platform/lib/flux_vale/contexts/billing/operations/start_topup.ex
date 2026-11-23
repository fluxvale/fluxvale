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
  `tax_cents` the VAT on it — always `FluxVale.Billing.Tax.quote/2`'s
  figure from the row's rate (0 when reverse-charge), never inlined
  twice. The rate table is the sole rate source (#260): the row's rate
  is resolved here from the billing country, never taken from the
  caller's `tax_rate_bp` — a caller rate or tax figure that contradicts
  the resolution fails the top-up closed (`:tax_rate_mismatch` /
  `:tax_cents_mismatch`) before anything is persisted or charged —
  under reverse charge only the tax figure is checked (the evidence
  zeroes the rate whatever the caller carried) — so the wizard's
  displayed total and the charge cannot fork. The gateway
  is charged the GROSS. `reverse_charge?` and `ip_matches_billing?`
  are derived here from the caller's evidence
  (`FluxVale.Billing.Tax`), so the recorded signals cannot fork from
  the buyer input.

  A top-up amount that is not on the ladder (#888, ADR-0046 Am. 2: a
  rung of `FluxVale.Billing.topup_ladder_cents/0`, or above its top
  rung) is refused (`:invalid_amount`) before anything is persisted or
  charged — the gateway's fixed per-checkout fee only amortizes from
  the ladder's floor up.

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
    # The floor is checked before any tax arithmetic: a negative or
    # non-integer amount must answer `:invalid_amount`, never
    # reach `Tax.tax_cents/2`'s non-negative guard.
    case check_amount(params.amount_cents) do
      :ok -> do_create_topup(org, params)
      error -> error
    end
  end

  defp do_create_topup(org, params) do
    customer_type = params[:customer_type] || :consumer

    # The full resolution — reverse charge, the fresh table rate (#260),
    # the tax figure — lives on Tax (the domain helper both lanes share).
    buyer_evidence = evidence(params, customer_type)
    tax = Tax.quote(buyer_evidence, params.amount_cents)

    # The resolved rate is authoritative: the tax is always the
    # helper's figure from it. A caller figure that contradicts it
    # fails closed before anything is persisted.
    with :ok <- check_tax_rate(params[:tax_rate_bp], tax.rate_bp, tax.reverse_charge?),
         :ok <- check_tax_cents(params[:tax_cents], tax.tax_cents) do
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
          tax_rate_bp: tax.rate_bp,
          tax_cents: tax.tax_cents,
          reverse_charge?: tax.reverse_charge?,
          ip_matches_billing?:
            Tax.ip_matches_billing?(
              params[:billing_country],
              params[:ip_country]
            )
        },
        authorize?: false
      )
    end
  end

  defp evidence(params, customer_type) do
    %{
      billing_country: params[:billing_country],
      billing_state: params[:billing_state],
      customer_type: customer_type,
      vat_number: params[:vat_number]
    }
  end

  # A supplied rate is a cross-check against the table's resolution,
  # never a source. Reverse charge skips it: the evidence zeroes the
  # rate whatever the caller carried (the tax check below still guards
  # the only figure that would persist).
  defp check_tax_rate(nil, _resolved, _reverse_charge?), do: :ok

  defp check_tax_rate(_supplied, _resolved, true), do: :ok

  defp check_tax_rate(supplied, resolved, false) when is_integer(supplied) do
    if supplied == resolved do
      :ok
    else
      {:error, :tax_rate_mismatch}
    end
  end

  # The ladder (#888): the wizard gates the amount with the same
  # predicate, this is the gate a crafted event cannot skip. The floor
  # exists because the gateway charges a fixed fee per checkout — see
  # FluxVale.Billing.min_topup_cents/0 — and the rungs keep small
  # top-ups to a predictable shape.
  defp check_amount(amount_cents) do
    if FluxVale.Billing.topup_amount_valid?(amount_cents) do
      :ok
    else
      {:error, :invalid_amount}
    end
  end

  # A supplied figure is a cross-check, never a source: only a caller
  # that computed the same tax from the authoritative rate may proceed.
  defp check_tax_cents(nil, _authoritative), do: :ok

  defp check_tax_cents(supplied, authoritative) when is_integer(supplied) do
    if supplied == authoritative do
      :ok
    else
      {:error, :tax_cents_mismatch}
    end
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
