defmodule FluxVale.Identity.Operations.PollDeviceCode do
  @moduledoc """
  The device-flow poll (#362 T3, RFC 8628 §3.5): the CLI's repeated
  `POST /api/v1/device/token`, answered from the row's state.

  The machine, in the order the endpoint answers:

  * unknown device_code / past `expires_at` / :expired / **:consumed**
    → `{:error, :expired_token}` — :consumed is the exactly-once
    latch: the token crossed the wire once and will not again (RFC
    8628 has no distinct "already used" error; expired_token is the
    shape every polling client already handles — GitHub answers it
    the same way)
  * :denied → `{:error, :access_denied}`
  * :pending → the interval machine: a poll sooner than `interval`
    after the last COUNTED poll is `{:error, :slow_down}` (the +5s
    backoff is the CLIENT's obligation, §3.5 — the wire keeps the
    constant; a refused poll never stamps `last_polled_at`, so a
    hammering client stays refused until it actually backs off).
    Otherwise `{:ok, %{status: :authorization_pending}}` and the row
    records the counted poll.
  * :approved → the one-time grant: `consume` flips the row first
    (guarded write — two racing polls have exactly one winner; the
    loser answers authorization_pending and its next poll reads
    :consumed), THEN the PAT mints. Consume-first trades a burned
    approval on a mid-mint failure for never double-minting a live
    token — the row's failure arm is a DB outage, where nothing
    useful survives anyway.

  The poll is unauthenticated (the device_code IS the credential) and
  reads/writes system-side (`authorize?: false` with comments — the
  RequestWindow posture); the PAT mint inside the success arm rides
  the actor's OWN create policy (self-mint), no bypass.
  """

  alias FluxVale.Identity
  alias FluxVale.Identity.DeviceCode
  alias FluxVale.Identity.DeviceCode.FirstPartyClient
  alias FluxVale.Identity.User

  require Logger

  # The PAT's display name for device mints — the provenance metadata
  # (client_id, grant_type, minted_via) is the machine-readable half.
  @pat_name "CLI sign-in"

  @grant_type "urn:ietf:params:oauth:grant-type:device_code"

  @doc """
  Polls `device_code` for `client_id` (must be the seeded first-party
  client — the same gate the mint rides).

  `opts` accepts `now:` (the clock read lives here so expiry and
  slow_down tests stay deterministic — the only injection point).

  Returns:

  * `{:ok, %{status: :authorization_pending}}` — keep polling
  * `{:error, :slow_down}` — polled too soon; back off §3.5
  * `{:error, :access_denied}` / `{:error, :expired_token}`
  * `{:error, {:invalid_client, client_id}}`
  * `{:error, {:poll_write_failed | :mint_failed, reason}}` — a
    mid-flow DB outage; not an RFC state, the controller answers 500
  * `{:ok, %{token:, pat:, expires_in:}}` — the grant; the raw
    `fvpat_` value crosses the wire THIS once
  """
  @spec call(String.t() | nil, String.t() | nil, keyword()) ::
          {:ok, %{status: :authorization_pending}}
          | {:ok,
             %{token: String.t(), pat: Identity.PersonalAccessToken.t(), expires_in: integer()}}
          | {:error, :slow_down | :access_denied | :expired_token}
          | {:error, {:invalid_client, String.t() | nil}}
          | {:error, {:poll_write_failed | :mint_failed, term()}}
  def call(client_id, device_code, opts \\ []) do
    with :ok <- validate_client(client_id) do
      case DeviceCode.get_by_device_code(device_code || "", authorize?: false) do
        {:ok, row} ->
          decide(row, Keyword.get(opts, :now, DateTime.utc_now()))

        # An unknown device_code answers expired_token, not "not
        # found" — RFC 8628 §3.5 has no invalid-credential error for
        # the poll, and a distinct answer would confirm which codes
        # exist (the wire's only enumeration surface).
        {:error, _not_found} ->
          {:error, :expired_token}
      end
    end
  end

  defp validate_client(client_id) do
    if client_id == FirstPartyClient.first_party_client_id() do
      :ok
    else
      {:error, {:invalid_client, client_id}}
    end
  end

  defp decide(row, now) do
    cond do
      expired?(row, now) ->
        {:error, :expired_token}

      row.status == :denied ->
        {:error, :access_denied}

      # Dead row (the exactly-once latch fired): expired_token, before
      # any timing — the token crossed the wire once and will not
      # again, however soon the next poll comes.
      row.status == :consumed ->
        {:error, :expired_token}

      row.status == :approved ->
        grant(row)

      # :pending — the only state with timing left to enforce.
      true ->
        pending(row, now)
    end
  end

  # Expiry rides the timestamp; the :expired status is part of the
  # state machine's vocabulary but nothing sets it (DeviceCode
  # moduledoc) — the check keeps it honest if a future writer does.
  defp expired?(row, now) do
    DateTime.compare(row.expires_at, now) == :lt or row.status == :expired
  end

  defp pending(row, now) do
    if too_soon?(row, now) do
      {:error, :slow_down}
    else
      count_poll(row)
    end
  end

  # The counted poll: stamps last_polled_at + bumps poll_count
  # (system write — the endpoint is the only caller). The write is the
  # poll's own record — a failure here is a DB outage, and the honest
  # answer is an error, never a lie-by-omission authorization_pending.
  defp count_poll(row) do
    case DeviceCode.touch_poll(row, authorize?: false) do
      {:ok, _row} ->
        Logger.info("device poll counted: row=#{row.id} poll_count=#{row.poll_count + 1}")

        {:ok, %{status: :authorization_pending}}

      # The write's still-pending guard lost a race the read missed:
      # approve/deny landed between decide/2's read and this write. A
      # state move, not an outage — the next poll reads the new state
      # (approved → the grant).
      # coveralls-ignore-start - the in-process read→write window is
      # not orderable in the suite.
      {:error, %Ash.Error.Invalid{errors: errors} = error} ->
        stale_or_error(errors, error)

      # coveralls-ignore-stop

      {:error, error} ->
        {:error, {:poll_write_failed, error}}
    end
  end

  # coveralls-ignore-start - the StaleRecord side of the race window
  # above (the arm this helper disambiguates).
  defp stale_or_error(errors, error) do
    if Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1)) do
      {:ok, %{status: :authorization_pending}}
    else
      {:error, {:poll_write_failed, error}}
    end
  end

  # coveralls-ignore-stop

  # Second-precision stamps (:utc_datetime): "sooner than interval"
  # compares whole seconds — polls in the same second as the last
  # counted one are always too soon (diff 0), which is the point.
  defp too_soon?(row, now) do
    case row.last_polled_at do
      nil ->
        false

      last_polled_at ->
        DateTime.diff(now, last_polled_at, :second) < poll_interval_seconds()
    end
  end

  defp grant(row) do
    # The exactly-once latch, BEFORE the mint: one winner, and a row
    # can never hand out two tokens. The loser's StaleRecord lands
    # here as an authorization_pending (its next poll reads
    # :consumed → expired_token).
    case DeviceCode.consume(row, authorize?: false) do
      {:ok, consumed} ->
        mint(consumed)

      # Lost the consume race — the winner is mid-mint; keep the
      # client polling (coveralls-ignore: needs two concurrent polls
      # between the read and the write — a timing window the suite
      # cannot order deterministically).
      # coveralls-ignore-start
      {:error, _lost_race} ->
        {:ok, %{status: :authorization_pending}}

        # coveralls-ignore-stop
    end
  end

  defp mint(row) do
    # The approver is the row's bound user: load them and self-mint —
    # the create policy authorizes user_id == actor.id, no bypass. A
    # deleted approver's rows are already gone (on_delete :delete), so
    # this only fails on a DB outage.
    user = Ash.get!(User, row.user_id, authorize?: false)

    case Identity.mint_pat(user, %{
           user_id: user.id,
           name: @pat_name,
           scopes: row.scopes,
           metadata: %{
             "client_id" => row.client_id,
             "grant_type" => "device_flow",
             "scopes" => row.scopes,
             "minted_via" => "device"
           }
         }) do
      {:ok, %{token: raw, pat: pat}} ->
        expires_in = DateTime.diff(pat.expires_at, DateTime.utc_now(), :second)

        Logger.info("device flow token issued: pat=#{pat.id} user=#{user.id}")

        {:ok, %{token: raw, pat: pat, expires_in: expires_in}}

      # Defensive: the mint's inputs were validated at device-code
      # mint time (catalog scopes, live user); this arm bounds a
      # DB-outage mid-grant — the approval burned (consume-first, see
      # the moduledoc), the error surfaces.
      # coveralls-ignore-start
      {:error, error} ->
        {:error, {:mint_failed, error}}

        # coveralls-ignore-stop
    end
  end

  @doc """
  The wire's `grant_type` — the controller validates the body against
  it (one tie, same module).
  """
  @spec grant_type() :: String.t()
  def grant_type, do: @grant_type

  @doc """
  The seconds between COUNTED polls — the mint response's `interval`.
  """
  @spec poll_interval_seconds() :: pos_integer()
  def poll_interval_seconds, do: 5
end
