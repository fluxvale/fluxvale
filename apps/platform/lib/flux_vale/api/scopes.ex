defmodule FluxVale.Api.Scopes do
  @moduledoc """
  The `/api/v1` scope catalog and route table (#360).

  The top-level `FluxVale.Api` namespace is new and deliberate: this
  is the API *boundary* concern — which token may cross into which
  route — not a domain. Resource policies stay scope-unaware
  (ADR-0019 Am. 1); this module is the single place that knows the
  catalog, the implication rule, and the route table.

  Scopes are `<domain>:<access>` strings over five domains. `write`
  implies `read` for its domain; `wallet` and `catalog` are read-only
  for now (a `write` scope for them is not in the catalog —
  validation rejects it). There is no admin scope.

  The route table maps `{method, path segments}` (under `/api/v1`,
  literals or `:_` wildcards) to the required scope, or `:any` for
  scopeless routes. It is written ONCE here, covering the whole S1
  route set (#360's plan); the coverage test asserts it both ways —
  every shipped route is mapped, and every pattern has a shipped
  route (a dead entry fails).
  """

  @read_domains [:instances, :backups, :gateways, :wallet, :catalog]
  @write_domains [:instances, :backups, :gateways]

  # The Ash request-context key carrying the calling PAT's scopes from
  # the boundary plug to /me's meta render (#484). ONE owner — the plug
  # writes it, the route reads it; drift here is a compile-time fix, not
  # a silent wrong answer (a bare atom in two modules degrades quietly
  # to "no scopes", indistinguishable from a session caller).
  @pat_scopes_context_key :pat_scopes

  @read_scopes Enum.map(@read_domains, &"#{&1}:read")
  @write_scopes Enum.map(@write_domains, &"#{&1}:write")

  @all_scopes @read_scopes ++ @write_scopes

  # One entry per {method, pattern} — a pattern is the path segments
  # under /api/v1, each a literal string or the `:_` wildcard. When
  # several patterns match, the most literal one wins (see
  # required_scope/2), so `["instances", :_, "backup-setting"]` beats
  # `["instances", :_]`.
  @route_table [
    # /me and the OpenAPI document are scopeless — any live token.
    {{"GET", ["me"]}, :any},
    {{"GET", ["open_api"]}, :any},
    # The actor's own orgs (#362 T6a): identity-adjacent like /me —
    # membership IS the policy (the action filters on the actor's
    # memberships), so the route takes no domain scope. Any live token
    # may learn which orgs it belongs to.
    {{"GET", ["organizations"]}, :any},
    # Instances.
    {{"GET", ["instances"]}, "instances:read"},
    {{"POST", ["instances"]}, "instances:write"},
    # #731 T2: the slug lookup (slug is unique only per cluster; the
    # optional organization_id query arg narrows it).
    {{"GET", ["instances", "by-slug", :_]}, "instances:read"},
    {{"GET", ["instances", :_]}, "instances:read"},
    {{"PATCH", ["instances", :_, "deploy"]}, "instances:write"},
    {{"PATCH", ["instances", :_, "stop"]}, "instances:write"},
    {{"PATCH", ["instances", :_, "start"]}, "instances:write"},
    {{"PATCH", ["instances", :_, "always-on"]}, "instances:write"},
    {{"PATCH", ["instances", :_, "exposure"]}, "instances:write"},
    # #493: the stopped-first resize rides the same write scope.
    {{"PATCH", ["instances", :_, "resize"]}, "instances:write"},
    # #731 T1: the in-place env merge.
    {{"PATCH", ["instances", :_, "env"]}, "instances:write"},
    # #250 (ADR-0046): the member storage-request verbs ride the
    # instances domain — approve/reject/retry stay web-only (no admin
    # scope exists).
    {{"POST", ["instances", :_, "storage-requests"]}, "instances:write"},
    {{"GET", ["instances", :_, "storage-requests"]}, "instances:read"},
    {{"GET", ["storage-requests", :_]}, "instances:read"},
    {{"DELETE", ["instances", :_]}, "instances:write"},
    # #597 S4: the PocketID wiring verb — an instance write.
    {{"POST", ["instances", :_, "connect-pocketid"]}, "instances:write"},
    # #731 T3: the wiring's other verbs — disconnect/rotate write, the
    # provider's state read is a plain instance read.
    {{"POST", ["instances", :_, "disconnect-pocketid"]}, "instances:write"},
    {{"POST", ["instances", :_, "rotate-pocketid-secret"]}, "instances:write"},
    {{"GET", ["instances", :_, "pocket-id-wiring"]}, "instances:read"},
    # Backups.
    {{"GET", ["instances", :_, "backup-setting"]}, "backups:read"},
    {{"GET", ["instances", :_, "backup-runs"]}, "backups:read"},
    {{"POST", ["instances", :_, "backup-setting"]}, "backups:write"},
    {{"PATCH", ["backup-settings", :_]}, "backups:write"},
    {{"DELETE", ["backup-settings", :_]}, "backups:write"},
    {{"POST", ["instances", :_, "backup-runs"]}, "backups:write"},
    {{"POST", ["instances", :_, "backup-runs", :_, "restore"]}, "backups:write"},
    # Access gateways.
    {{"GET", ["organizations", :_, "access-gateway"]}, "gateways:read"},
    {{"POST", ["access-gateways"]}, "gateways:write"},
    {{"PATCH", ["access-gateways", :_, "resume"]}, "gateways:write"},
    {{"POST", ["access-gateways", :_, "attachments"]}, "gateways:write"},
    {{"DELETE", ["access-gateways", :_, "attachments", :_]}, "gateways:write"},
    # Access domains (#482, ADR-0040): custom domains serve the
    # private-access edge, so they ride the gateways domain — no new
    # scope string, the catalog stays five domains.
    {{"POST", ["access-domains"]}, "gateways:write"},
    {{"GET", ["organizations", :_, "access-domains"]}, "gateways:read"},
    {{"GET", ["access-domains", :_]}, "gateways:read"},
    {{"PATCH", ["access-domains", :_, "resume"]}, "gateways:write"},
    {{"DELETE", ["access-domains", :_]}, "gateways:write"},
    # Wallet (read-only in S1).
    {{"GET", ["organizations", :_, "wallet"]}, "wallet:read"},
    {{"GET", ["organizations", :_, "wallet", "runway"]}, "wallet:read"},
    {{"GET", ["wallets", :_, "ledger-entries"]}, "wallet:read"},
    # Catalog (read-only in S1).
    {{"GET", ["apps"]}, "catalog:read"},
    {{"GET", ["apps", :_]}, "catalog:read"},
    {{"GET", ["apps", :_, "versions"]}, "catalog:read"},
    {{"GET", ["app-versions", :_]}, "catalog:read"}
  ]

  @doc """
  Every grantable scope string in the S1 catalog.
  """
  @spec all_scopes() :: [String.t()]
  def all_scopes, do: @all_scopes

  @doc """
  The Ash request-context key the boundary plug writes the calling
  PAT's scopes under (#484) — `/me`'s meta render reads the same key.
  """
  @spec pat_scopes_context_key() :: atom()
  def pat_scopes_context_key, do: @pat_scopes_context_key

  @doc """
  The route table itself — `{{method, pattern}, scope}` pairs — for
  the coverage test's reverse direction (a pattern no shipped route
  matches is a dead entry).
  """
  @spec route_table() :: [{{String.t(), [String.t() | :_]}, :any | String.t()}]
  def route_table, do: @route_table

  @doc """
  Is `scope` a catalog scope? (`wallet:write` and unknown domains are
  not — there is no grantable write scope for them in S1.)
  """
  @spec valid_scope?(String.t()) :: boolean()
  def valid_scope?(scope) when is_binary(scope), do: scope in @all_scopes
  def valid_scope?(_other), do: false

  @doc """
  Validates a scope list for minting: every entry must be in the
  catalog and appear at most once.

  Returns `:ok` or `{:error, {:invalid_scope, scope}}` /
  `{:error, {:duplicate_scope, scope}}`.
  """
  @spec validate([String.t()]) :: :ok | {:error, {:invalid_scope | :duplicate_scope, String.t()}}
  def validate(scopes) do
    cond do
      duplicate = find_duplicate(scopes) ->
        {:error, {:duplicate_scope, duplicate}}

      invalid = Enum.find(scopes, &(not valid_scope?(&1))) ->
        {:error, {:invalid_scope, invalid}}

      true ->
        :ok
    end
  end

  @doc """
  Does `granted` cover `required`? An exact match always does, and a
  domain's `write` grant covers its `read` scope (write implies
  read). `read` never implies `write`.
  """
  @spec grants?([String.t()], String.t()) :: boolean()
  def grants?(granted, required) do
    required in granted or write_counterpart(required) in granted
  end

  @doc """
  The required scope for `method` + `path_segments` (the segments
  under `/api/v1`).

  Returns `{:ok, scope}` (a scope string, or `:any` for scopeless
  routes) or `:error` when no pattern matches — the deny-by-default
  arm the boundary plug turns into a 403 for token callers.
  """
  @spec required_scope(String.t() | atom(), [String.t()]) :: {:ok, String.t() | :any} | :error
  def required_scope(method, segments) do
    # Callers arrive with both shapes — conn.method is an uppercase
    # string, ash_json_api route entities carry lowercase atoms.
    normalized = String.upcase("#{method}")

    matches =
      Enum.filter(@route_table, fn {{mapped_method, pattern}, _scope} ->
        mapped_method == normalized and matches?(pattern, segments)
      end)

    case most_specific(matches) do
      nil -> :error
      {_pattern, scope} -> {:ok, scope}
    end
  end

  # Length must match and every position must agree — a literal only
  # equals its string, the `:_` atom (the table's wildcard) matches
  # any one segment.
  defp matches?(pattern, segments) when length(pattern) == length(segments) do
    pattern
    |> Enum.zip(segments)
    |> Enum.all?(fn
      {:_, _segment} -> true
      {literal, segment} -> literal == segment
    end)
  end

  defp matches?(_pattern, _segments), do: false

  # Most literals wins — the longest/most-specific pattern. An empty
  # match list (the `fn -> nil` fallback) is the :error arm above.
  defp most_specific(matches) do
    Enum.max_by(
      matches,
      fn {{_method, pattern}, _scope} -> literal_count(pattern) end,
      fn -> nil end
    )
  end

  defp literal_count(pattern), do: Enum.count(pattern, &is_binary/1)

  defp find_duplicate(scopes) do
    Enum.find(scopes, fn scope -> Enum.count(scopes, &(&1 == scope)) > 1 end)
  end

  # "instances:read" -> "instances:write". For anything that isn't a
  # :read scope the counterpart equals the input, which the first
  # membership test already covered — the second test is then a
  # harmless repeat.
  defp write_counterpart(required), do: String.replace_suffix(required, ":read", ":write")
end
