defmodule FluxValeWeb.Webhooks.Plumbing do
  @moduledoc """
  The transport half shared by the provider webhook controllers
  (HitPay, Polar): raw-body reading, JSON parsing, the verify-error
  responses, and the credit-result response.

  Provider-specific pieces stay in each controller: signature
  verification, event decoding, and the terminal-outcome list.
  """

  require Logger

  @spec read_raw_body(Plug.Conn.t()) :: {:ok, binary()} | {:error, :no_raw_body}
  def read_raw_body(conn) do
    case conn.assigns[:raw_body] do
      body when is_binary(body) and byte_size(body) > 0 -> {:ok, body}
      _empty -> {:error, :no_raw_body}
    end
  end

  @spec parse_payload(binary()) :: {:ok, map()} | {:error, :invalid_json}
  def parse_payload(raw_body) do
    case Phoenix.json_library().decode(raw_body) do
      {:ok, parsed} when is_map(parsed) -> {:ok, parsed}
      {:ok, _non_object} -> {:error, :invalid_json}
      # Unreachable through the endpoint: Plug.Parsers raises ParseError
      # (400) on undecodable bodies before the router. Defense-in-depth
      # for callers of the controller outside the endpoint pipeline.
      # coveralls-ignore-next-line
      {:error, _decode_error} -> {:error, :invalid_json}
    end
  end

  @spec verify_error(Plug.Conn.t(), term(), String.t(), String.t()) :: Plug.Conn.t()
  def verify_error(conn, :no_raw_body, provider, _config_noun) do
    Logger.error("#{provider} webhook rejected: no raw body in conn (RawBody plug misconfigured)")

    conn
    |> Plug.Conn.put_status(:internal_server_error)
    |> Phoenix.Controller.json(%{error: "misconfigured"})
  end

  def verify_error(conn, verification, provider, _config_noun)
      when verification in [:missing_signature, :signature_mismatch] do
    Logger.warning("#{provider} webhook rejected: #{inspect(verification)}")

    conn
    |> Plug.Conn.put_status(:unauthorized)
    |> Phoenix.Controller.json(%{error: "invalid_signature"})
  end

  def verify_error(conn, :missing_config, provider, config_noun) do
    Logger.error("#{provider} webhook rejected: webhook #{config_noun} not configured")

    conn
    |> Plug.Conn.put_status(:internal_server_error)
    |> Phoenix.Controller.json(%{error: "misconfigured"})
  end

  def verify_error(conn, :invalid_json, provider, _config_noun) do
    # Valid signature, unusable payload — retrying won't help.
    Logger.warning("#{provider} webhook rejected: invalid JSON payload")
    Phoenix.Controller.json(conn, %{received: true})
  end

  @spec respond(term(), Plug.Conn.t(), String.t(), [atom()]) :: Plug.Conn.t()
  def respond(result, conn, provider, terminal_outcomes) do
    case result do
      {:ok, _result} ->
        Phoenix.Controller.json(conn, %{received: true})

      :ok ->
        Phoenix.Controller.json(conn, %{received: true})

      # Terminal mismatches — retrying can't change them; the error log
      # is the operator signal.
      {:error, reason} ->
        if reason in terminal_outcomes do
          Logger.error("#{provider} webhook not credited, #{inspect(reason)}")
          Phoenix.Controller.json(conn, %{received: true})
        else
          # A credit that failed on a payment we accepted — 500 so the
          # provider retries (the idempotency key makes the retry safe).
          Logger.error("#{provider} webhook credit failed: #{inspect(reason)}")

          conn
          |> Plug.Conn.put_status(:internal_server_error)
          |> Phoenix.Controller.json(%{error: "internal_error"})
        end
    end
  end
end
