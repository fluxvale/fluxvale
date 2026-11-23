defmodule FluxVale.OAuth.Operations.PollDeviceGrant do
  @moduledoc """
  The device-grant poll (#886, RFC 8628 §3.5): the CLI's repeated
  `POST /oauth/token` with the device grant, answered from the row's
  state.

  The machine, in the order the endpoint answers:

  * unknown device_code → `expired_token`
  * a device_code issued to another client → `invalid_grant` (checked
    before status dispatch so a stranger's poll cannot mutate
    `last_polled_at`/`poll_count` or observe grant state)
  * past `expires_at` / :expired / **:consumed** → `expired_token` —
    :consumed is the exactly-once latch: the pair crossed the wire
    once and will not again (RFC 8628 has no distinct "already used"
    error; expired_token is the shape every polling client already
    handles — the Identity device flow's answer)
  * :denied → `access_denied`
  * :pending → the interval machine: a poll sooner than `interval`
    after the last COUNTED poll is `slow_down` (the +5s backoff is the
    CLIENT's obligation, §3.5; a refused poll never stamps
    `last_polled_at`, so a hammering client stays refused until it
    actually backs off). Otherwise `authorization_pending` and the row
    records the counted poll.
  * :approved → the PKCE door, then the one-time grant: the verifier
    must hash to the mint-time challenge (`invalid_grant` without
    consuming — a wrong local process that stole the device_code still
    cannot redeem, and the 256-bit verifier space plus the endpoint's
    per-IP window bound guessing; burning the row here would punish a
    client bug with a full restart). Then `consume` flips the row
    first (guarded write — two racing polls have exactly one winner;
    the loser answers authorization_pending and its next poll reads
    :consumed), THEN the pair mints through the shared
    `mint_tokens` (family, resource, advisory lock, tombstone check).

  The poll is unauthenticated (the device_code IS the capability) and
  reads/writes system-side (`authorize?: false` with comments — the
  RequestWindow posture).
  """

  alias FluxVale.Identity.PersonalAccessToken
  alias FluxVale.OAuth.Client
  alias FluxVale.OAuth.DeviceGrant
  alias FluxVale.OAuth.PKCE

  require Logger

  @grant_type "urn:ietf:params:oauth:grant-type:device_code"

  @doc """
  Polls `params` (`%{client_id:, device_code:, code_verifier:}`).

  `opts` accepts `now:` (the clock read lives here so expiry and
  slow_down tests stay deterministic — the Identity poll's only
  injection point).

  Returns:

  * `{:ok, token_response}` — the grant; `fvoat_`/`fvort_` cross the
    wire THIS once (`access_token`, `token_type`, `expires_in`,
    `refresh_token`, `scope`)
  * `{:error, {:authorization_pending | :slow_down | :access_denied |
    :expired_token | :invalid_client | :invalid_grant |
    :server_error, description}}` — RFC 8628 §3.5 shapes in the §5.2
    envelope
  """
  @spec call(map(), keyword()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def call(params, opts \\ []) do
    device_code_hash = hash(param(params, :device_code))

    with {:ok, client} <- fetch_client(param(params, :client_id)) do
      case DeviceGrant.get_by_device_code_hash(device_code_hash, authorize?: false) do
        {:ok, grant} ->
          decide(grant, client, params, Keyword.get(opts, :now, DateTime.utc_now()))

        # An unknown device_code answers expired_token, not "not
        # found" — RFC 8628 §3.5 has no invalid-credential error for
        # the poll, and a distinct answer would confirm which codes
        # exist (the wire's only enumeration surface; the Identity
        # poll's answer).
        {:error, _not_found} ->
          {:error, expired_token_error()}
      end
    end
  end

  defp decide(grant, client, params, now) do
    case client_match(grant, client) do
      :ok -> dispatch(grant, client, params, now)
      {:error, _reason} = error -> error
    end
  end

  defp dispatch(grant, client, params, now) do
    cond do
      expired?(grant, now) ->
        {:error, expired_token_error()}

      grant.status == :denied ->
        {:error, {:access_denied, "the authorization request was denied"}}

      # Dead row (the exactly-once latch fired): expired_token, before
      # any timing — the pair crossed the wire once and will not
      # again, however soon the next poll comes.
      grant.status == :consumed ->
        {:error, expired_token_error()}

      grant.status == :approved ->
        grant_pair(grant, client, params)

      # :pending — the only state with timing left to enforce.
      true ->
        pending(grant, now)
    end
  end

  # Expiry rides the timestamp; the :expired status is part of the
  # state machine's vocabulary but nothing sets it (DeviceGrant
  # moduledoc) — the check keeps it honest if a future writer does.
  defp expired?(grant, now) do
    DateTime.compare(grant.expires_at, now) == :lt or grant.status == :expired
  end

  defp pending(grant, now) do
    if too_soon?(grant, now) do
      {:error,
       {:slow_down,
        "polled sooner than the interval. Back off #{poll_interval_seconds()} seconds"}}
    else
      count_poll(grant)
    end
  end

  # The counted poll: stamps last_polled_at + bumps poll_count
  # (system write — the token endpoint is the only caller). The write
  # is the poll's own record — a failure here is a DB outage, and the
  # honest answer is an error, never a lie-by-omission
  # authorization_pending (the Identity poll's stance).
  defp count_poll(grant) do
    case DeviceGrant.touch_poll(grant, authorize?: false) do
      {:ok, _grant} ->
        {:error, {:authorization_pending, "approval still pending"}}

      # The write's still-pending guard lost a race the read missed:
      # approve/deny landed between decide/4's read and this write. A
      # state move, not an outage — the next poll reads the new state
      # (approved → the grant).
      # coveralls-ignore-start - the in-process read→write window is
      # not orderable in the suite (the Identity poll's stance).
      {:error, %Ash.Error.Invalid{errors: errors} = error} ->
        stale_or_error(errors, error)

      # coveralls-ignore-stop

      # coveralls-ignore-start - a DB outage mid-poll: the arm's head
      # is a stop word, but the body lines need the block; internals
      # go to the log, static words to the wire.
      {:error, error} ->
        Logger.error("device grant poll write failed: #{inspect(error)}")
        {:error, {:server_error, "the poll could not be recorded"}}

        # coveralls-ignore-stop
    end
  end

  # coveralls-ignore-start - the StaleRecord side of the race window
  # above (the arm this helper disambiguates).
  defp stale_or_error(errors, error) do
    if Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1)) do
      {:error, {:authorization_pending, "approval still pending"}}
    else
      Logger.error("device grant poll write failed: #{inspect(error)}")
      {:error, {:server_error, "the poll could not be recorded"}}
    end
  end

  # coveralls-ignore-stop

  # Second-precision stamps (:utc_datetime): "sooner than interval"
  # compares whole seconds — polls in the same second as the last
  # counted one are always too soon (diff 0), which is the point (the
  # Identity poll's shape).
  defp too_soon?(grant, now) do
    case grant.last_polled_at do
      nil ->
        false

      last_polled_at ->
        DateTime.diff(now, last_polled_at, :second) < poll_interval_seconds()
    end
  end

  defp grant_pair(grant, client, params) do
    verifier = param(params, :code_verifier)

    case verify_pkce(grant, verifier) do
      :ok -> consume_and_mint(grant, client)
      {:error, _reason} = error -> error
    end
  end

  # A device_code issued to another client never burns the row — the
  # stranger's probe is refused before any state moves.
  defp client_match(grant, client) do
    if grant.client_id == client.id do
      :ok
    else
      {:error, {:invalid_grant, "device_code was issued to another client"}}
    end
  end

  # The mint-time S256 challenge (the issue's security shape): the
  # verifier must hash to it. A mismatch does NOT consume — the row is
  # not burned by a wrong guess (the 256-bit space and the endpoint's
  # per-IP window bound guessing; the honest CLI retries with its
  # verifier).
  defp verify_pkce(grant, verifier) do
    if PKCE.verify(verifier, grant.code_challenge) do
      :ok
    else
      {:error, {:invalid_grant, "code_verifier does not match the PKCE challenge"}}
    end
  end

  defp consume_and_mint(grant, client) do
    # The exactly-once latch, BEFORE the mint: one winner, and a row
    # can never hand out two pairs. The loser's StaleRecord answers
    # authorization_pending (its next poll reads :consumed →
    # expired_token).
    case DeviceGrant.consume(grant, authorize?: false) do
      {:ok, consumed} ->
        mint(consumed, client)

      # Lost the consume race — the winner is mid-mint; keep the
      # client polling (the Identity poll's stance).
      # coveralls-ignore-start - needs two concurrent polls between
      # the read and the write — a timing window the suite cannot
      # order deterministically.
      {:error, _lost_race} ->
        {:error, {:authorization_pending, "approval still pending"}}

        # coveralls-ignore-stop
    end
  end

  defp mint(grant, client) do
    family_id = Ash.UUIDv7.generate()

    mint_params = %{
      client: client,
      user_id: grant.user_id,
      scopes: grant.scopes,
      resource: grant.resource,
      family_id: family_id,
      grant_type: @grant_type
    }

    case FluxVale.OAuth.mint_tokens(mint_params) do
      {:ok, minted} ->
        FluxVale.OAuth.record_audit_event(%{
          kind: :device_grant_token_issued,
          oauth_client_id: client.id,
          actor_id: grant.user_id,
          token_family_id: family_id,
          resource: grant.resource,
          metadata: %{"scopes" => grant.scopes}
        })

        Client.touch_last_used(client, authorize?: false)

        Logger.info("device grant pair issued: client=#{client.client_id} user=#{grant.user_id}")

        {:ok,
         %{
           access_token: minted.access_token,
           token_type: "Bearer",
           expires_in: minted.expires_in,
           refresh_token: minted.refresh_token,
           scope: Enum.join(grant.scopes, " ")
         }}

      # coveralls-ignore-start - a tombstoned family cannot predate
      # the device grant (the family is minted here, fresh); the guard
      # is the shared mint's.
      {:error, :connection_revoked} ->
        {:error, {:invalid_grant, "the connection has been revoked"}}

      # coveralls-ignore-stop

      # coveralls-ignore-start - DB outage mid-mint; the token
      # endpoint answers server_error and the client restarts the
      # flow (the approval burned — consume-first, the Identity
      # poll's trade).
      {:error, _error} ->
        {:error, {:server_error, "could not issue the token pair"}}
        # coveralls-ignore-stop
    end
  end

  defp fetch_client(client_id) when is_binary(client_id) and client_id != "" do
    case Client.get_by_client_id(client_id, authorize?: false) do
      {:ok, client} -> {:ok, client}
      {:error, _not_found} -> {:error, {:invalid_client, "unknown client"}}
    end
  end

  defp fetch_client(_client_id), do: {:error, {:invalid_client, "client_id is required"}}

  # A malformed device_code (a JSON map/number — query brackets and
  # bodies decode to non-binaries) must never reach :crypto: hash the
  # empty string and let the lookup answer expired_token, the §5.2
  # envelope instead of a 500 (every sibling input path has its own
  # is_binary guard; this one pre-hashes outside any cast).
  defp hash(device_code) when is_binary(device_code),
    do: PersonalAccessToken.token_hash(device_code)

  defp hash(_device_code), do: PersonalAccessToken.token_hash("")

  defp expired_token_error,
    do: {:expired_token, "the device code is expired or already used"}

  defp param(params, key) do
    Map.get(params, key) || Map.get(params, Atom.to_string(key))
  end

  @doc """
  The wire's `grant_type` — the token endpoint routes on it (one tie,
  same module).
  """
  @spec grant_type() :: String.t()
  def grant_type, do: @grant_type

  @doc """
  The seconds between COUNTED polls — the resource's constant, the
  same one the mint response's `interval` reads (one tie).
  """
  @spec poll_interval_seconds() :: pos_integer()
  def poll_interval_seconds, do: DeviceGrant.poll_interval_seconds()
end
