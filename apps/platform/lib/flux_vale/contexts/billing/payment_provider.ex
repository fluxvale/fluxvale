defmodule FluxVale.Billing.PaymentProvider do
  @moduledoc """
  The payments adapter contract (ADR-0029): one behaviour, pluggable
  gateway implementations, one active provider via config
  (`config :flux_vale, :payments_provider`). v1's Dodo modules
  (`fluxvale_old`: `billing/dodo.ex` + `dodo/webhook.ex`) are the
  reference port.

  Providers are stateless modules. Each resolves its own credentials
  from its app-env block (HitPay: `config :flux_vale, :hitpay`) —
  secrets arrive via env/BWS (ADR-0021), never the repo.
  `create_checkout/2`'s `opts` merge over that block so a caller can pin
  a run (sandbox keys, base URL) without app-env writes; verification
  and reconciliation run in server contexts and self-resolve.

  The wallet never knows the provider: the ledger's idempotency keys
  are `<provider>:<payment_id>`, postings ride the existing operations
  — switching gateways is a one-module swap (ADR-0029).

  ## The staged off-session lane (#829)

  Four callbacks cover the auto-recharge lane — `create_billing_session/2`
  (the pre-authenticated portal where a buyer saves a method),
  `list_payment_methods/1` (existence + default reference),
  `create_draft_charge/2` (a draft order — creation never charges), and
  `finalize_charge/2` (the synchronous charge attempt). Providers adopt
  the behaviour with `use FluxVale.Billing.PaymentProvider`, which
  injects default implementations answering `{:error, :unsupported}`
  for exactly these four (`defoverridable` — Polar overrides, dormant
  HitPay answers the default); the original three callbacks have no
  defaults and every provider implements them.
  """

  @typedoc """
  The checkout inputs. `amount_cents` is integer US cents (the ledger's
  unit — providers format it for their wire format); `reference` is our
  id for the purchase (HitPay: reference_number), echoed in webhooks.
  """
  @type checkout_request :: %{
          required(:amount_cents) => pos_integer,
          required(:currency) => String.t(),
          required(:reference) => String.t(),
          required(:redirect_url) => String.t(),
          optional(:email) => String.t() | nil,
          optional(:name) => String.t() | nil
        }

  @typedoc "The hosted-checkout handle: the gateway's payment-request id and the URL to send the buyer to."
  @type checkout :: %{payment_request_id: String.t(), checkout_url: String.t()}

  @typedoc "Normalized payment-request state for reconciliation."
  @type payment :: %{
          required(:payment_request_id) => String.t(),
          required(:status) => atom(),
          required(:amount_cents) => non_neg_integer(),
          required(:payments) => list(%{id: String.t(), status: atom()})
        }

  @typedoc """
  The billing-session inputs (#829): open the customer-portal session
  where a buyer saves a payment method. `organization_id` is our org id
  (the provider-side `external_id`); `email`/`name` are the buyer
  identity, nil when the org has none; `billing_address` is the
  evidence the provider taxes against — `country` required, `state`
  when the country has one.
  """
  @type billing_session_request :: %{
          required(:organization_id) => Ash.UUID.t(),
          required(:email) => String.t() | nil,
          required(:name) => String.t() | nil,
          required(:billing_address) => %{country: String.t(), state: String.t() | nil}
        }

  @typedoc "The portal handle: the provider customer id and the one-time portal URL to redirect to."
  @type billing_session :: %{customer_id: String.t(), portal_url: String.t()}

  @typedoc """
  The draft-charge inputs (#829): the same money discipline as
  `checkout_request` — integer gross `amount_cents`; `reference` is our
  topup id and rides the order's metadata. `currency` documents the
  gross's unit for the caller; providers derive it from the product.
  """
  @type draft_charge_request :: %{
          required(:amount_cents) => pos_integer,
          required(:currency) => String.t(),
          required(:reference) => String.t()
        }

  @typedoc "The draft-order handle: the provider order id (persist BEFORE any charge trigger) and the echoed amount."
  @type draft_charge :: %{order_id: String.t(), amount_cents: non_neg_integer()}

  @typedoc """
  The answered charge (#829): `:completed` when the provider reports
  the order paid, `:failed` an answered decline (402/403/412 — a
  result, never an error). `amount_cents` is what the provider echoed,
  nil when a failed response carries none; `failure_reason` names the
  decline, nil on completion.
  """
  @type charge_outcome :: %{
          required(:order_id) => String.t(),
          required(:amount_cents) => non_neg_integer() | nil,
          required(:status) => :completed | :failed,
          required(:failure_reason) => String.t() | nil
        }

  # :unsupported rides the injected off-session-lane defaults — an
  # adopter answering through a default clause, never a gateway fault.
  @type error ::
          :missing_config | :invalid_response | :api_error | :network_error | :unsupported

  @callback create_checkout(request :: checkout_request(), opts :: keyword()) ::
              {:ok, checkout()} | {:error, error()}

  @doc """
  Verifies a webhook delivery — constant-time compare (ADR-0029), the
  signature scheme lives inside the adapter. `signature` is the
  provider's header value as received (nil when absent).
  """
  @callback verify_webhook(raw_body :: binary(), signature :: String.t() | nil) ::
              :ok | {:error, :missing_signature | :missing_config | :signature_mismatch}

  @callback fetch_payment(payment_request_id :: String.t()) ::
              {:ok, payment()} | {:error, error()}

  @doc """
  Opens the pre-authenticated customer-portal session where the buyer
  saves a payment method (#829). `opts` merge over the provider's app
  env like `create_checkout/2`.
  """
  @callback create_billing_session(request :: billing_session_request(), opts :: keyword()) ::
              {:ok, billing_session()} | {:error, error()}

  @doc """
  The saved-method summary the sweep gates on (#829): how many methods
  the provider customer has and the default's reference — existence
  and default, never the instruments.
  """
  @callback list_payment_methods(provider_customer_id :: String.t()) ::
              {:ok, non_neg_integer(), String.t() | nil} | {:error, error()}

  @doc """
  Creates a DRAFT order for the gross (#829) — creation never charges;
  the returned order id is persisted before any charge trigger.
  `opts[:customer_id]` (the provider customer id) is required.
  """
  @callback create_draft_charge(request :: draft_charge_request(), opts :: keyword()) ::
              {:ok, draft_charge()} | {:error, error()}

  @doc """
  The synchronous charge attempt on a draft order (#829). A
  402/403/412 is an ANSWERED failure (`{:ok, …, status: :failed}`),
  not an error — only unknown outcomes are `{:error, …}`.
  """
  @callback finalize_charge(order_id :: String.t(), opts :: keyword()) ::
              {:ok, charge_outcome()} | {:error, error()}

  # Default clauses ride `use`, not plain defs on this module: Elixir
  # warns on every unimplemented non-optional @callback even when the
  # behaviour defines defaults (probed 2026-11-17 — plain defs here
  # still fail `mix compile --warnings-as-errors` on a non-implementing
  # provider), and @optional_callbacks is banned — a non-implementer
  # would crash on the call instead of answering. Injection gives every
  # adopter the {:error, :unsupported} answers; defoverridable lets an
  # implementing provider override (docs/plans/829 #S1).
  @doc """
  Adopts the behaviour with the staged off-session lane's defaults:
  `create_billing_session/2`, `list_payment_methods/1`,
  `create_draft_charge/2`, and `finalize_charge/2` answer
  `{:error, :unsupported}` unless overridden.
  """
  defmacro __using__(_opts) do
    quote do
      @behaviour unquote(__MODULE__)

      def create_billing_session(_request, _opts), do: {:error, :unsupported}

      def list_payment_methods(_provider_customer_id), do: {:error, :unsupported}

      def create_draft_charge(_request, _opts), do: {:error, :unsupported}

      def finalize_charge(_order_id, _opts), do: {:error, :unsupported}

      defoverridable create_billing_session: 2,
                     list_payment_methods: 1,
                     create_draft_charge: 2,
                     finalize_charge: 2
    end
  end
end
