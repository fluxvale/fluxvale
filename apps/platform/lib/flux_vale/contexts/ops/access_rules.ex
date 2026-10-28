defmodule FluxVale.Ops.AccessRules do
  @moduledoc """
  The access evaluator — the only sanctioned way to ask "may this address
  hold an account / keep access?" (ADR-0023 §1 + Am. 1). Never read
  `AccessRule` rows ad hoc.

  Semantics: **empty table = unrestricted; any row = allowlist** — an
  address is allowed iff it matches an exact email row or its domain
  *equals* a domain row (exact match; subdomains do not inherit).
  Deliberately fail-open on empty: that IS prod's pre-beta state;
  environments that must gate enter their own rows (settled on #26).

  Enforcement boundaries (all settled on #26; #285 T3 generalizes the
  session/token edges to the user):

  - **code-send** — `FluxVale.Identity.Operations.RequestAuthCode` (the
    JIT gate: no code sent, no account created, therefore no PAT) —
    still address-level (`ensure_allowed/1`: a code is only ever sent
    to an allowed address)
  - **session mint** — `VerifyAuthCode` before token mint + `SessionController`
    before the session write (closes the ≤10-min window where a rule was
    removed after a code was already sent) — user-level
    (`ensure_allowed_user/1`) since T3: a user signs in with any of
    their verified addresses
  - **token presentation** — `FluxValeWeb.Plugs.Authenticate` and the
    LiveView on_mount gate, where PAT bearer and session validation
    converge — user-level as above: ANY verified address passing the
    allowlist keeps the account connected; severing requires every
    verified address denied

  Reads consult `AccessRules.Cache` (60s snapshot, bust-on-mutation) —
  revocation latency is instant on the mutating node and TTL-bounded
  cross-node. The cache is disabled in test config (instant consistency);
  `decide/2` is the pure core, kept public for tests and the future
  curated admin view.
  """

  alias FluxVale.Identity.UserEmail
  alias FluxVale.Ops.AccessRule
  alias FluxVale.Ops.AccessRules.Cache

  # Ash.Query.filter is a macro
  require Ash.Query

  @typedoc "An AccessRule row as stored (any shape the resource can hold)."
  @type rule_row :: %AccessRule{}

  @doc """
  Is `email` allowed? Case-insensitive on both the address and domain rows.
  """
  @spec allowed?(String.t() | Ash.CiString.t()) :: boolean()
  def allowed?(email) do
    snapshot = fetch_snapshot()
    decide(snapshot, email)
  end

  @doc """
  The gate form of `allowed?/1` for `with` chains (#26): `:ok` when the
  address is allowed, `{:error, :not_allowed}` when a rule denies it.
  """
  @spec ensure_allowed(String.t() | Ash.CiString.t()) :: :ok | {:error, :not_allowed}
  def ensure_allowed(email) do
    case allowed?(email) do
      true -> :ok
      false -> {:error, :not_allowed}
    end
  end

  @doc """
  The user-level gate (#285 T3): `:ok` when ANY verified address of the
  user passes the allowlist, `{:error, :not_allowed}` otherwise. A
  single-address user behaves exactly as `ensure_allowed/1` on that
  address; a user with several addresses stays connected while one good
  address remains. A user with no verified address is severed — nothing
  proven, nothing granted.

  authorize?: false — the system seam: this runs for an
  already-authenticated user on every session/token presentation;
  UserEmail's actor-shaped reads are not the gate's question.
  """
  @spec ensure_allowed_user(FluxVale.Identity.User.t()) :: :ok | {:error, :not_allowed}
  def ensure_allowed_user(user) do
    verified_addresses =
      UserEmail
      |> Ash.Query.filter(user_id == ^user.id and not is_nil(verified_at))
      |> Ash.Query.select(:address)
      |> Ash.read!(authorize?: false)
      |> Enum.map(& &1.address)

    if Enum.any?(verified_addresses, &allowed?/1) do
      :ok
    else
      {:error, :not_allowed}
    end
  end

  @doc """
  The decision core: what do `rules` (the table snapshot) mean for `email`?

  Pure — no lookup, no policy, no clock. Empty list = unrestricted;
  otherwise an exact email match or an exact domain match allows.
  """
  @spec decide([rule_row()], String.t() | Ash.CiString.t()) :: boolean()
  def decide([], _email), do: true

  def decide(rules, email) do
    address =
      email
      |> to_string()
      |> String.downcase()

    domain =
      address
      |> String.split("@")
      |> List.last()

    Enum.any?(rules, &rule_allows?(&1, address, domain))
  end

  defp rule_allows?(%AccessRule{email: rule_email}, address, _domain)
       when not is_nil(rule_email) do
    rule_email
    |> to_string()
    |> String.downcase()
    |> then(&(&1 == address))
  end

  defp rule_allows?(%AccessRule{domain: rule_domain}, _address, domain)
       when not is_nil(rule_domain) do
    rule_domain
    |> to_string()
    |> String.downcase()
    |> then(&(&1 == domain))
  end

  # Unreachable through the resource (one_of validation) — total by
  # construction for hand-built rows in tests.
  # coveralls-ignore-start - the one_of validation above makes this total
  defp rule_allows?(_inert_row, _address, _domain), do: false
  # coveralls-ignore-stop

  defp fetch_snapshot do
    if Cache.enabled?(), do: Cache.snapshot(), else: Cache.read_all()
  end
end
