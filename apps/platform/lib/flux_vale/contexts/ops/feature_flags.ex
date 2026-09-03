defmodule FluxVale.Ops.FeatureFlags do
  @moduledoc """
  The flag evaluator — the only sanctioned way to ask "is this on for this
  actor?" (ADR-0023 §2 + Am. 4). Never read `FeatureFlag` rows ad hoc.

  The call signature follows FunWithFlags (Am. 4: the interface adopted,
  the library not) — muscle memory carries over:

      FeatureFlags.enabled?(:forgejo_deploys)
      FeatureFlags.enabled?(:forgejo_deploys, for: user)
      FeatureFlags.enable(:forgejo_deploys, actor: admin)
      FeatureFlags.enable(:forgejo_deploys, percentage: 50, actor: admin)
      FeatureFlags.disable(:forgejo_deploys, actor: admin)

  Reads (`enabled?`) are the product-facing edge: declare-gated, row
  fetched uncached — correct and instantly consistent (~1 ms at beta
  scale; short-TTL ETS caching only if metrics ever demand it).
  `decide/3` is the decision core, pure given the row — kept public
  because the deferred curated flag view (ADR-0023 Am. 2) will want
  exactly this over rows it already holds.

  Decision semantics:

  - **missing row = disabled** — fail-closed: no row anywhere means the new
    thing is off everywhere (prod-safe before seeds).
  - **undeclared key raises** — data absence (no row) fails closed, but a
    typo'd key is a *code bug* and gets a loud `ArgumentError` instead of a
    silent `false` that can never turn on. Writes are declare-gated too:
    the verbs refuse to mint rows no read can ever reach.
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
  Is `key` enabled, anonymous evaluation? Same as `enabled?(key, for: nil)`.
  """
  @spec enabled?(atom()) :: boolean()
  def enabled?(key) when is_atom(key), do: enabled?(key, for: nil)

  @doc """
  Is `key` enabled for `actor`? `key` must be declared in `@known_flags`.
  """
  @spec enabled?(atom(), for: Ash.Resource.record() | map() | nil) :: boolean()
  def enabled?(key, for: actor) when is_atom(key) do
    declared!(key)

    # authorize?: false — machine read of global config, same posture as
    # the seeds bootstrap. Flags aren't actor-scoped data; the read is not
    # an authorization question (mutations stay admin-gated, see the
    # resource's policies and the verbs below).
    key
    |> Atom.to_string()
    |> FeatureFlag.by_key!(authorize?: false, not_found_error?: false)
    |> decide(key, actor)
  end

  @doc """
  Enable `key`, authorized by `actor:` (a platform admin — the policy
  decides, not this module).

  Options:

  - `actor:` (required) — the acting admin record
  - `percentage:` (optional) — sets the rollout; omit to keep the row's
    existing `rollout_percentage` (nil on a fresh row = everyone)

  Creates the row if absent. Returns `:ok | {:error, reason}` (FunWithFlags
  convention, Am. 4).
  """
  @spec enable(atom(), keyword()) :: :ok | {:error, term()}
  def enable(key, opts) when is_atom(key) and is_list(opts) do
    declared!(key)

    actor = Keyword.fetch!(opts, :actor)
    # Explicit nil check, not ||: `0` is truthy so `||` handled it, but a
    # falsy bogus value (`percentage: false`) rode into "not given" and
    # silently preserved the old rollout instead of failing validation
    # (CodeRabbit, #36).
    given_pct = Keyword.get(opts, :percentage)
    key_str = Atom.to_string(key)

    outcome =
      case row(key_str) do
        nil ->
          FeatureFlag.create(key_str, %{enabled: true, rollout_percentage: given_pct},
            actor: actor
          )

        flag ->
          preserve = if is_nil(given_pct), do: flag.rollout_percentage, else: given_pct

          Ash.update(flag, %{enabled: true, rollout_percentage: preserve}, actor: actor)
      end

    case outcome do
      {:ok, _flag} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Disable `key`, authorized by `actor:` — keeps the row's
  `rollout_percentage` so a later `enable/2` resumes the same rollout.
  A no-op when no row exists (absence already means disabled — no row is
  materialized for a flag that never existed).

  Returns `:ok | {:error, reason}`.
  """
  @spec disable(atom(), keyword()) :: :ok | {:error, term()}
  def disable(key, opts) when is_atom(key) and is_list(opts) do
    declared!(key)

    # No row → already disabled by absence; nothing to materialize (Am. 4)
    outcome =
      case row(Atom.to_string(key)) do
        nil -> {:ok, nil}
        flag -> Ash.update(flag, %{enabled: false}, actor: Keyword.fetch!(opts, :actor))
      end

    case outcome do
      {:ok, _flag} -> :ok
      {:error, reason} -> {:error, reason}
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

  # Enum.member? over `in`: the empty list must not trip the compiler's
  # "always false" warning — mechanism-first means @known_flags is [] for now.
  defp declared!(key) do
    if not Enum.member?(@known_flags, key) do
      raise ArgumentError,
            "undeclared feature flag #{inspect(key)} — declare it in " <>
              "FluxVale.Ops.FeatureFlags's @known_flags before gating on it"
    end
  end

  defp row(key_str) do
    FeatureFlag.by_key!(key_str, authorize?: false, not_found_error?: false)
  end
end
