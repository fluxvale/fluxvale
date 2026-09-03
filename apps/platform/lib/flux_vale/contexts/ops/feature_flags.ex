defmodule FluxVale.Ops.FeatureFlags do
  @moduledoc """
  The flag evaluator — the only sanctioned way to ask "is this on for this
  actor?" (ADR-0023 §2). Never read `FeatureFlag` rows ad hoc.

  Two layers:

  - `enabled?/2` is the product-facing edge: declare-gates the key, fetches
    the row (uncached — correct and instantly consistent, ~1 ms at beta
    scale; short-TTL ETS caching only if metrics ever demand it).
  - `decide/3` is the decision core, pure given the row — kept public
    because the deferred curated flag view (ADR-0023 Am. 2) will want
    exactly this over rows it already holds.

  Decision semantics:

  - **missing row = disabled** — fail-closed: no row anywhere means the new
    thing is off everywhere (prod-safe before seeds).
  - **undeclared key raises** — data absence (no row) fails closed, but a
    typo'd key is a *code bug* and gets a loud `ArgumentError` instead of a
    silent `false` that can never turn on.
  - **percentage rollouts are sticky** — `:erlang.phash2({key, user_id})`
    rem 100 < pct buckets each user deterministically; no flip-flopping
    between requests. Actors we cannot bucket — anonymous (nil) or an
    id-less map — fail closed on partial rollouts: treating all such
    traffic as one unit would make pct an all-or-nothing switch for
    visitors. Full-on flags (enabled, nil pct) apply to everyone,
    anonymous included — flags gate what visitors see too.

  Per-env values are free by construction: staging and prod have separate
  databases (ADR-0010).
  """

  alias FluxVale.Ops.FeatureFlag

  @typedoc "A FeatureFlag row as stored (any shape the resource can hold)."
  @type flag_row :: %FeatureFlag{}

  # The declared flag catalog — atom safety lives here (ADR-0023 §2): DB
  # string keys convert to atoms ONLY through this list, never through
  # String.to_atom/1 on DB input (the v1 catalog-seeds lesson).
  #
  # Mechanism-first (#25): the list ships EMPTY — fail-closed makes that
  # correct, and no M2 code branches on a flag yet. The first entry arrives
  # with the first real gated feature (M3+), same PR as its code branch.
  @known_flags []

  @doc """
  Is `key` enabled for `actor`? `key` must be declared in `@known_flags`.
  """
  @spec enabled?(atom(), Ash.Resource.record() | map() | nil) :: boolean()
  def enabled?(key, actor) when is_atom(key) do
    # Enum.member? over `in`: the empty list must not trip the compiler's
    # "always false" warning — mechanism-first means @known_flags is [] for now.
    if Enum.member?(@known_flags, key) do
      # authorize?: false — machine read of global config, same posture as
      # the seeds bootstrap. Flags aren't actor-scoped data; the read is not
      # an authorization question (mutations stay admin-gated, see the
      # resource's policies).
      key
      |> Atom.to_string()
      |> FeatureFlag.by_key!(authorize?: false, not_found_error?: false)
      |> decide(key, actor)
    else
      raise ArgumentError,
            "undeclared feature flag #{inspect(key)} — declare it in " <>
              "FluxVale.Ops.FeatureFlags's @known_flags before gating on it"
    end
  end

  @doc """
  The decision core: what does `flag` (nil = missing row) mean for `actor`?

  Pure — no lookup, no policy, no clock. `key` is the declared atom used
  for sticky bucketing.
  """
  @spec decide(flag_row() | nil, atom(), Ash.Resource.record() | map() | nil) :: boolean()
  def decide(nil, _key, _actor), do: false

  def decide(%FeatureFlag{enabled: false}, _key, _actor), do: false

  def decide(%FeatureFlag{enabled: true, rollout_percentage: nil}, _key, _actor), do: true

  def decide(%FeatureFlag{enabled: true, rollout_percentage: _pct}, _key, nil), do: false

  def decide(%FeatureFlag{enabled: true, rollout_percentage: pct}, key, %{id: id}) do
    # Sticky bucketing per ADR-0023 §2. NB: phash2 guarantees stability
    # within an OTP release, not across them — a deliberate major-bump
    # (exact-pinned toolchain) may rebucket users once. Revisit trigger:
    # a rebucketed rollout ever causing real confusion.
    rem(:erlang.phash2({key, id}), 100) < pct
  end

  # Unbucketable actor — a map with no :id (the spec admits any map):
  # fail closed, same posture as the nil actor above.
  def decide(%FeatureFlag{enabled: true, rollout_percentage: _pct}, _key, _id_less), do: false
end
