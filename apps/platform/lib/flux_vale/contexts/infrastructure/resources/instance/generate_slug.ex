defmodule FluxVale.Infrastructure.Instance.GenerateSlug do
  @moduledoc """
  Generates the Instance's slug — and with it the DNS subdomain and the
  user-facing URL — in the Haikunator format (`adjective-noun-1234`,
  the Fly.io/Heroku convention v1 used).

  Collision-checked per cluster with up to 3 retries; the DB identity is
  the source of truth (the read-before-write probe is a TOCTOU trade-off
  v1 documented and kept: 40.96M combinations (64x64x10k), 50% collision
  odds only at ~7,500 instances per cluster, a clear error on the rare
  race).

  Uniqueness is per cluster only, and the deployed envs share the
  `*.fluxvale.app` wildcard — so the env-scoped prefix (#155) is the
  collision policy: prod (no `INSTANCES_SLUG_PREFIX`) mints bare labels;
  a non-prod env sets a prefix (staging: `stg`) and can never take a
  prod label.
  """

  use Ash.Resource.Change

  alias FluxVale.Infrastructure.Instance

  require Ash.Query

  @max_retries 3

  # Haikunator-style adjectives (same as Heroku/Fly.io, v1 port)
  @adjectives ~w(
    autumn hidden bitter misty silent empty dry dark summer
    icy delicate quiet white cool spring winter patient
    twilight dawn crimson wispy weathered blue billowing
    broken cold damp falling frosty green long late lingering
    bold little morning muddy old red rough still small
    sparkling thrumming shy wandering withered wild black
    young holy solitary fragrant aged snowy proud floral
    restless divine polished ancient purple lively nameless
  )

  # Haikunator-style nouns (same as Heroku/Fly.io, v1 port)
  @nouns ~w(
    waterfall river breeze moon rain wind sea morning
    snow lake sunset pine shadow leaf dawn glitter forest
    hill cloud meadow sun glade bird brook butterfly
    bush dew dust field fire flower firefly feather grass
    haze mountain night pond darkness snowflake silence
    sound sky shape surf thunder violet water wildflower
    wave water resonance sun log dream cherry tree fog
    frost voice paper frog smoke star
  )

  @max_adjective_length @adjectives
                        |> Enum.map(&String.length/1)
                        |> Enum.max()

  @max_noun_length @nouns
                   |> Enum.map(&String.length/1)
                   |> Enum.max()

  # Longest generated slug ("adjective-noun-####"): adjective + "-" +
  # noun + "-" + 4 digits, from the word lists above.
  @max_haikunate_length @max_adjective_length + @max_noun_length + 6

  # Prefix bound: prefix + "-" + the longest slug ≤ 63 (DNS label).
  @max_prefix_length 63 - 1 - @max_haikunate_length

  # \z, not $ — `$` also matches before a trailing newline, so a value
  # with a trailing "\n" would clear boot validation and then mint a slug
  # instance-create rejects (fails safe, but the guard should hold).
  @prefix_format ~r/^[a-z0-9]([a-z0-9-]*[a-z0-9])?\z/

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    cluster_id = Ash.Changeset.get_attribute(changeset, :cluster_id)

    case generate_unique_slug(cluster_id, @max_retries) do
      {:ok, slug} ->
        Ash.Changeset.force_change_attribute(changeset, :slug, slug)

      # coveralls-ignore-start - defensive: extremely unlikely (40.96M
      # combinations, 50% collision at ~7,500 instances per cluster)
      {:error, :collision} ->
        Ash.Changeset.add_error(
          changeset,
          field: :slug,
          message:
            "unable to generate a unique name after #{@max_retries} attempts - please try again"
        )

        # coveralls-ignore-stop
    end
  end

  @doc """
  Generates a unique haikunate-style slug with collision detection.
  """
  @spec generate_unique_slug(String.t() | nil, non_neg_integer()) ::
          {:ok, String.t()} | {:error, :collision}
  def generate_unique_slug(cluster_id, retries_remaining \\ @max_retries)

  def generate_unique_slug(_cluster_id, 0), do: {:error, :collision}

  def generate_unique_slug(cluster_id, retries_remaining) do
    slug = apply_prefix(generate_haikunate_slug())

    if slug_exists?(slug, cluster_id) do
      # retry recursion: only reachable on a random-draw collision
      # coveralls-ignore-next-line
      generate_unique_slug(cluster_id, retries_remaining - 1)
    else
      {:ok, slug}
    end
  end

  # Internal collision probe — authorize?: false (the creating actor may
  # not read other users' instances; uniqueness here is a write concern,
  # not an exposure). On exception, assume free: the DB identity decides.
  defp slug_exists?(slug, cluster_id) when is_binary(cluster_id) do
    Instance
    |> Ash.Query.filter(slug == ^slug and cluster_id == ^cluster_id)
    |> Ash.exists?(authorize?: false)
  rescue
    # coveralls-ignore-next-line - defensive: DB constraint owns uniqueness on exception
    _exception -> false
  end

  defp slug_exists?(_slug, nil), do: false

  @doc """
  Generates a haikunate-style slug: adjective-noun-####
  """
  @spec generate_haikunate_slug() :: String.t()
  def generate_haikunate_slug do
    adjective = Enum.random(@adjectives)
    noun = Enum.random(@nouns)

    formatted_number =
      9999
      |> :rand.uniform()
      |> Integer.to_string()
      |> String.pad_leading(4, "0")

    "#{adjective}-#{noun}-#{formatted_number}"
  end

  @doc """
  Applies the env-scoped prefix (`config :flux_vale,
  :instances_slug_prefix`, set from `INSTANCES_SLUG_PREFIX`) to a base
  slug. nil — the prod default — and "" mint bare labels.
  """
  @spec apply_prefix(String.t()) :: String.t()
  def apply_prefix(base) do
    case Application.get_env(:flux_vale, :instances_slug_prefix) do
      prefix when prefix in [nil, ""] -> base
      prefix -> "#{prefix}-#{base}"
    end
  end

  @doc """
  Validates the `INSTANCES_SLUG_PREFIX` value (runtime.exs calls this at
  boot, so a bad value fails the deploy, not the first instance create):
  DNS-label shape, and short enough that prefix + the longest generated
  slug stays within the 63-char DNS label.
  """
  @spec validate_prefix!(String.t() | nil) :: :ok
  def validate_prefix!(prefix) when prefix in [nil, ""], do: :ok

  def validate_prefix!(prefix) do
    cond do
      not Regex.match?(@prefix_format, prefix) ->
        raise ArgumentError,
              "INSTANCES_SLUG_PREFIX #{inspect(prefix)} is not a DNS label " <>
                "(lowercase letters, digits and hyphens, no leading/trailing " <>
                "hyphen) — fix the env var and redeploy"

      String.length(prefix) > @max_prefix_length ->
        raise ArgumentError,
              "INSTANCES_SLUG_PREFIX #{inspect(prefix)} is too long " <>
                "(#{String.length(prefix)} chars; the bound is #{@max_prefix_length} " <>
                "so prefix + slug stays within the 63-char DNS label) — " <>
                "fix the env var and redeploy"

      true ->
        :ok
    end
  end

  @impl Ash.Resource.Change
  # coveralls-ignore-next-line trivial callback — always false (reads another table)
  def atomic?, do: false
end
