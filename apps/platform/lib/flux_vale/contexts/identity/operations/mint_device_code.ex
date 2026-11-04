defmodule FluxVale.Identity.Operations.MintDeviceCode do
  @moduledoc """
  Mints one device-flow sign-in request (#362 T3, OQ #9's wire): the
  `device_code` for the CLI's poll loop, the `user_code` for its
  human, 10 minutes to approve.

  Unauthenticated by design — the caller is a device with no token
  yet; the endpoint is how it earns one. The gates are the catalog
  (scopes) and the seeded first-party client (client_id), both
  validated before anything is generated, with the resource-level
  validations as the second door.
  """

  alias FluxVale.Api.Scopes
  alias FluxVale.Identity.DeviceCode
  alias FluxVale.Identity.DeviceCode.FirstPartyClient

  require Logger

  # 32 random bytes → 43 url-safe chars (the PAT random's shape).
  @device_code_bytes 32

  # 8 chars over 31 no-confusables symbols (no I/L/O/0/1): a human
  # types or compares this, so lookalikes are engineered out, and the
  # display shape is XXXX-XXXX (RFC 8628 §3.3.1 suggests
  # user-friendliness).
  @user_code_alphabet ~c"ABCDEFGHJKMNPQRSTUVWXYZ23456789"
  @user_code_length 8

  # The user_code space is 32^8 ≈ 2.25e12 — a collision retry is
  # astronomically defensive; the loop is the race-proofing anyway
  # (two concurrent mints drew the same code).
  @user_code_retries 5

  @doc """
  Mints a device code for `params`: `%{client_id:, scopes:}` (scopes
  may be empty — a full-access token mints with no entries; OQ #9's
  "full access" first-party shape). Returns `{:ok, %DeviceCode{}}` or

  * `{:error, {:invalid_client, client_id}}` — unknown client
  * `{:error, {:invalid_scope, scope}}` / `{:error, {:duplicate_scope, scope}}`
  * `{:error, changeset}` — a resource-level guard refused (second door)
  """
  @spec call(map(), keyword()) :: {:ok, DeviceCode.t()} | {:error, term()}
  def call(params, opts \\ []) do
    # System mint: the endpoint is unauthenticated BY DESIGN (the
    # device has no token yet — the flow is how it earns one), so
    # there is no actor to authorize and none to default-forbid
    # against (the RequestWindow posture, stated here).
    opts = Keyword.put_new(opts, :authorize?, false)

    scopes = params[:scopes] || []

    with :ok <- validate_client(params[:client_id]),
         :ok <- Scopes.validate(scopes) do
      expires_at = DateTime.add(DateTime.utc_now(), DeviceCode.ttl_seconds(), :second)

      create_row(
        %{
          device_code: device_code(),
          user_code: user_code(),
          client_id: params[:client_id],
          scopes: scopes,
          expires_at: expires_at
        },
        @user_code_retries,
        opts
      )
    end
  end

  # The mint logs the request shape, never either code value: the
  # device_code is the poll capability, the user_code is half of the
  # human comparison — neither belongs in logs.
  defp create_row(attrs, retries_left, opts) do
    case DeviceCode
         |> Ash.Changeset.for_create(:create, attrs, opts)
         |> Ash.create() do
      {:ok, row} ->
        minted_message =
          "device code minted: client=#{row.client_id} scopes=#{Enum.join(row.scopes, ",")}"

        Logger.info(minted_message)

        {:ok, row}

      # The unique_user_code arm — retry with a fresh draw. Any other
      # failure is a real refusal (or a DB outage): surface it.
      # coveralls-ignore-start - the arm needs create/1 to fail inside
      # the mint: either the 1-in-32^8 user_code collision draw (the
      # retry) or a DB outage mid-create — the matcher is unit-tested
      # directly; neither arm is orderable in the suite.
      {:error, error} ->
        if retries_left > 0 and user_code_taken?(error) do
          create_row(%{attrs | user_code: user_code()}, retries_left - 1, opts)
        else
          {:error, error}
        end

        # coveralls-ignore-stop
    end
  end

  @doc """
  Does `error` carry the user_code unique-violation (the retry's
  matcher)? Public so the suite can test the shape the DB hands back
  without forcing an actual collision draw.
  """
  @spec user_code_taken?(term()) :: boolean()
  def user_code_taken?(%Ash.Error.Invalid{errors: errors}) do
    Enum.any?(errors, fn
      %Ash.Error.Changes.InvalidAttribute{} = e ->
        e.field == :user_code and String.contains?("#{e.message}", "has already been taken")

      _other ->
        false
    end)
  end

  def user_code_taken?(_other), do: false

  defp validate_client(client_id) do
    if client_id == FirstPartyClient.first_party_client_id() do
      :ok
    else
      {:error, {:invalid_client, client_id}}
    end
  end

  defp device_code do
    @device_code_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp user_code do
    symbols =
      Enum.map(1..@user_code_length, fn _i -> Enum.random(@user_code_alphabet) end)

    # "XXXX-XXXX" — the dash is display: it splits the 8 symbols the
    # way the panel and the terminal show them.
    {left, right} = Enum.split(symbols, 4)
    IO.iodata_to_binary([left, ?-, right])
  end
end
