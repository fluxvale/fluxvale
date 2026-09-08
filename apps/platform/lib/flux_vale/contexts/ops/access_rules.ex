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

  Enforcement boundaries (all settled on #26):

  - **code-send** — `FluxVale.Identity.Operations.RequestAuthCode` (the
    JIT gate: no code sent, no account created, therefore no PAT)
  - **session mint** — `VerifyAuthCode` before token mint + `SessionController`
    before the session write (closes the ≤10-min window where a rule was
    removed after a code was already sent)
  - **token presentation** — `FluxValeWeb.Plugs.Authenticate`, where PAT
    bearer and session validation converge

  Reads consult `AccessRules.Cache` (60s snapshot, bust-on-mutation) —
  revocation latency is instant on the mutating node and TTL-bounded
  cross-node. The cache is disabled in test config (instant consistency);
  `decide/2` is the pure core, kept public for tests and the future
  curated admin view.
  """

  alias FluxVale.Ops.AccessRule
  alias FluxVale.Ops.AccessRules.Cache

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
  defp rule_allows?(_inert_row, _address, _domain), do: false

  defp fetch_snapshot do
    if Cache.enabled?(), do: Cache.snapshot(), else: Cache.read_all()
  end
end
