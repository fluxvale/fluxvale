defmodule FluxVale.Ops.AccessRules do
  @moduledoc """
  The access evaluator — the only sanctioned way to ask "may this address
  hold an account / keep access?" (ADR-0023 §1 + Am. 1). Never read
  `AccessRule` rows ad hoc.

  Semantics, per purpose (one table, disjoint allowlists — rows of the
  other purpose never match):

  - **`:auth`** — **empty :auth table = unrestricted; any rows =
    allowlist** — an address is allowed iff it matches an exact email
    row or its domain *equals* a domain row (exact match; subdomains do
    not inherit). Deliberately fail-open on empty: that IS prod's
    pre-beta state; environments that must gate enter their own rows
    (settled on #26). This semantics is load-bearing for the staging
    gate and PAT auth — do not change it.
  - **`:feedback`** (the feedback-board write gate's launch arm,
    ADR-0026 §3) — **fail-closed: an empty :feedback table = NOBODY
    allowlisted**. An empty write-gate must not become an open gate.

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
  `decide/3` is the pure core, kept public for tests and the future
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
  Is `email` allowed? The :auth purpose — the staging-entry/PAT gate
  semantics, unchanged: case-insensitive on both the address and domain
  rows.
  """
  @spec allowed?(String.t() | Ash.CiString.t()) :: boolean()
  def allowed?(email), do: allowed?(:auth, email)

  @doc """
  The purpose-aware edge (fluxvale/fluxvale#412): `:auth` keeps today's
  semantics EXACTLY — an empty :auth table is unrestricted entry (the
  staging gate and PAT auth ride it). `:feedback` is fail-closed — an
  empty :feedback table allowlists NOBODY. A table holding only rows of
  the other purpose is empty FOR THAT PURPOSE: purposes are disjoint
  allowlists over one table.
  """
  @spec allowed?(:auth | :feedback, String.t() | Ash.CiString.t()) :: boolean()
  def allowed?(purpose, email) do
    snapshot = fetch_snapshot()
    decide(purpose, snapshot, email)
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

    # One snapshot for the whole check — re-fetching per address would
    # multiply reads and could straddle a mid-check mutation
    snapshot = fetch_snapshot()

    if Enum.any?(verified_addresses, &decide(snapshot, &1)) do
      :ok
    else
      {:error, :not_allowed}
    end
  end

  @doc """
  The decision core under :auth — what do `rules` (the table snapshot)
  mean for `email`? The auth semantics unchanged.

  Pure — no lookup, no policy, no clock.
  """
  @spec decide([rule_row()], String.t() | Ash.CiString.t()) :: boolean()
  def decide(rules, email), do: decide(:auth, rules, email)

  @doc """
  The purpose-aware decision core: what do `rules` mean for `email`
  under `purpose`?

  Pure — no lookup, no policy, no clock. Rules are filtered to
  `purpose` first; emptiness then means the OPPOSITE per purpose:
  `:auth` unrestricted (the fail-open face), anything else nobody
  (fail-closed — an empty write-gate must not open the gate; an
  undeclared purpose fails closed with it).
  """
  @spec decide(:auth | :feedback | atom(), [rule_row()], String.t() | Ash.CiString.t()) ::
          boolean()
  # :auth's fail-open face: an empty table is unrestricted entry.
  def decide(:auth, [], _email), do: true

  # :feedback's fail-closed face: an empty write-gate is an open gate
  # waiting to happen — nobody passes.
  def decide(:feedback, [], _email), do: false

  def decide(purpose, rules, email) do
    purpose_rules = Enum.filter(rules, &(&1.purpose == purpose))

    case purpose_rules do
      # Only rows of the other purpose: empty FOR THIS PURPOSE. :auth
      # stays unrestricted (the semantics the staging gate depends on);
      # every other purpose stays shut.
      [] -> purpose == :auth
      _rules -> any_rule_allows?(purpose_rules, email)
    end
  end

  defp any_rule_allows?(rules, email) do
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
