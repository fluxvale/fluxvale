defmodule FluxVale.OAuth.Operations.MintDeviceGrant do
  @moduledoc """
  Mints one OAuth device-grant request (#886): the `device_code` for
  the CLI's poll loop, the `user_code` for the hosted page, 10 minutes
  to approve.

  The remote/headless answer to the loopback callback: the caller is
  the CLI (or any registered client) with no token and no listener —
  unauthenticated by design, the per-IP window on the endpoint bounds
  minting. The gates are the client registry, the S256 challenge, the
  scope catalog, and the resource allowlist — the same rules
  `ValidateAuthorizeRequest` enforces for the redirect flow, so the
  two grants cannot drift apart in what they allow.

  Beyond RFC 8628: the mint carries an S256 PKCE challenge and the
  poll must present its verifier — the `device_code` alone (read from
  process memory or a store by a wrong local process) cannot redeem.
  """

  alias FluxVale.Api.Scopes
  alias FluxVale.Identity.PersonalAccessToken
  alias FluxVale.OAuth.Client
  alias FluxVale.OAuth.DeviceGrant
  alias FluxVale.OAuth.PKCE
  alias FluxVale.OAuth.Resources

  require Logger

  # 32 random bytes → 43 url-safe chars (the PAT random's shape); only
  # the SHA-256 hash is stored.
  @device_code_bytes 32

  # 8 chars over 31 no-confusables symbols (no I/L/O/0/1; the Identity
  # device flow's alphabet — a human compares this against their
  # terminal), display shape XXXX-XXXX.
  @user_code_alphabet "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
  @user_code_alphabet_size byte_size(@user_code_alphabet)
  @user_code_length 8

  # The user_code space is 31^8 ≈ 8.5e11 — a collision retry is
  # astronomically defensive; the loop is the race-proofing anyway.
  @user_code_retries 5

  @doc """
  Mints a device grant for `params`: `%{client_id:, scope:,
  resource:, code_challenge:, code_challenge_method:}` (`scope` may be
  empty or absent — an identify-only grant; `resource` absent binds
  the configured default and marks it for the audit row).

  Returns `{:ok, %{grant: DeviceGrant.t(), device_code: String.t(),
  expires_in: integer(), interval: pos_integer(),
  resource_defaulted: boolean()}}` or

  * `{:error, {:invalid_client, description}}` — unknown client
  * `{:error, {:invalid_request, description}}` — missing/invalid S256
    challenge, malformed scope or resource
  * `{:error, {:invalid_scope, description}}` — unknown or duplicate
  * `{:error, {:invalid_target, description}}` — resource not served
  """
  @spec call(map(), keyword()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def call(params, opts \\ []) do
    # System mint: the endpoint is unauthenticated BY DESIGN (the
    # CLI has no token yet — the grant is how it earns one), so there
    # is no actor to authorize (the RequestWindow posture).
    opts = Keyword.put_new(opts, :authorize?, false)

    with {:ok, client} <- fetch_client(param(params, :client_id)),
         :ok <- challenge(param(params, :code_challenge), param(params, :code_challenge_method)),
         {:ok, scopes} <- scopes(param(params, :scope)),
         {:ok, resource, defaulted?} <- resource(param(params, :resource)) do
      mint_grant(client, scopes, resource, defaulted?, params, opts)
    end
  end

  defp mint_grant(client, scopes, resource, defaulted?, params, opts) do
    device_code = device_code()
    expires_at = DateTime.add(DateTime.utc_now(), DeviceGrant.ttl_seconds(), :second)

    attrs = %{
      device_code_hash: PersonalAccessToken.token_hash(device_code),
      user_code: user_code(),
      scopes: scopes,
      resource: resource,
      code_challenge: param(params, :code_challenge),
      expires_at: expires_at,
      client_id: client.id
    }

    case create_row(attrs, @user_code_retries, opts) do
      {:ok, grant} ->
        # The audit logs the request shape, never the device_code
        # value (the poll capability) — the wire's only secret.
        FluxVale.OAuth.record_audit_event(%{
          kind: :device_grant_minted,
          oauth_client_id: client.id,
          resource: resource,
          metadata: %{
            "scopes" => scopes,
            "resource_defaulted" => defaulted?
          }
        })

        # Bound first so the log call stays one line (the Identity
        # mint's shape — a wrapped Logger leaves an uncovered
        # continuation line in the coverage report).
        minted_message =
          "device grant minted: client=#{client.client_id} scopes=#{Enum.join(scopes, ",")}"

        Logger.info(minted_message)

        {:ok,
         %{
           grant: grant,
           device_code: device_code,
           expires_in: DeviceGrant.ttl_seconds(),
           interval: poll_interval_seconds(),
           resource_defaulted: defaulted?
         }}

      # coveralls-ignore-start - a resource-level guard refused (or a
      # DB outage): the operation pre-validates everything the
      # resource validates, so the arm is not reachable in the suite
      # — the wire's generic refusal is the honest answer.
      {:error, _refused} ->
        {:error, {:invalid_request, "the device grant could not be minted"}}

        # coveralls-ignore-stop
    end
  end

  defp create_row(attrs, retries_left, opts) do
    changeset = Ash.Changeset.for_create(DeviceGrant, :mint, attrs, opts)

    case Ash.create(changeset) do
      {:ok, row} ->
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
  without forcing an actual collision draw (the Identity mint's
  posture).
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

  defp fetch_client(client_id) when is_binary(client_id) and client_id != "" do
    case Client.get_by_client_id(client_id, authorize?: false) do
      {:ok, client} -> {:ok, client}
      {:error, _not_found} -> {:error, {:invalid_client, "unknown client"}}
    end
  end

  defp fetch_client(_client_id), do: {:error, {:invalid_client, "client_id is required"}}

  # The redirect flow's own rule (ValidateAuthorizeRequest's pkce/2):
  # S256 and a valid challenge, no plain, no missing.
  defp challenge(challenge, "S256") do
    if PKCE.valid_challenge?(challenge, "S256") do
      :ok
    else
      {:error, {:invalid_request, "a valid S256 code_challenge is required"}}
    end
  end

  defp challenge(_challenge, _method),
    do: {:error, {:invalid_request, "PKCE with S256 is required"}}

  # The redirect flow's own scope rule: space-delimited, catalog or
  # offline_access, no duplicates — offline_access stripped before the
  # row (the no-op, advertised and never stored).
  defp scopes(nil), do: {:ok, []}

  defp scopes(scope) when is_binary(scope) do
    scope_list =
      scope
      |> String.split()
      |> Enum.reject(&(&1 == ""))

    validate_scope_list(scope_list)
  end

  defp scopes(scope) when is_list(scope) do
    if Enum.all?(scope, &is_binary/1) do
      validate_scope_list(scope)
    else
      {:error, {:invalid_scope, "scope must be a space-delimited string"}}
    end
  end

  defp scopes(_scope), do: {:error, {:invalid_scope, "scope must be a space-delimited string"}}

  defp validate_scope_list(scopes) do
    case Scopes.validate_oauth(scopes) do
      :ok ->
        {:ok, Scopes.strip_oauth(scopes)}

      {:error, {:invalid_scope, invalid}} ->
        {:error, {:invalid_scope, "scope #{invalid} is not supported"}}

      {:error, {:duplicate_scope, duplicate}} ->
        {:error, {:invalid_scope, "scope #{duplicate} is repeated"}}
    end
  end

  # The redirect flow's own resource rule: absent binds the configured
  # default (older clients), present must match the allowlist exactly.
  defp resource(nil), do: {:ok, Resources.default(), true}

  defp resource(resource) when is_binary(resource) do
    if Resources.valid?(resource) do
      {:ok, resource, false}
    else
      {:error, {:invalid_target, "resource is not served by this authorization server"}}
    end
  end

  defp resource(_resource), do: {:error, {:invalid_target, "resource must be a URI"}}

  defp param(params, key) do
    Map.get(params, key) || Map.get(params, Atom.to_string(key))
  end

  defp device_code do
    @device_code_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp user_code do
    symbols =
      Enum.map(1..@user_code_length, fn _i ->
        index = :crypto.strong_rand_range(@user_code_alphabet_size)
        :binary.at(@user_code_alphabet, index)
      end)

    # "XXXX-XXXX" — the dash is display: it splits the 8 symbols the
    # way the hosted page and the terminal show them.
    {left, right} = Enum.split(symbols, 4)
    IO.iodata_to_binary([left, ?-, right])
  end

  @doc """
  The seconds between COUNTED polls — the mint response's `interval`
  (the resource's constant; one tie).
  """
  @spec poll_interval_seconds() :: pos_integer()
  def poll_interval_seconds, do: DeviceGrant.poll_interval_seconds()
end
