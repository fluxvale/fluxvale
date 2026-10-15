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

  @type error :: :missing_config | :invalid_response | :api_error | :network_error

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
end
