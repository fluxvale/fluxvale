defmodule FluxValeWeb.AdminConsole do
  @moduledoc """
  The generic resource console's exposure registry (#595, the plan at
  docs/plans/595-resource-console.md): the ONLY hand-maintained surface
  and the security boundary — ADR-0027 §3's opt-in posture, owned by
  the console instead of ash_admin's `admin show?`. Every URL segment
  under /admin/resources resolves against these entries and nothing
  else (string compare over existing atoms, never `String.to_atom/1`
  on input), and every read runs with the operator as actor under the
  resource policies.

  The registry parity test (test/flux_vale_web/admin_console_test.exs)
  walks the configured ash_domains against this module: any domain or
  resource neither included nor excluded BY NAME fails CI — new
  resources force a decision here, never a silent surface.
  """

  @type domain :: %{
          key: atom(),
          label: String.t(),
          module: module(),
          resources: [resource()]
        }
  @type resource :: %{key: atom(), module: module(), config: map()}

  # Live domains in display order, each with its resources. Slice 1
  # ships Ops only (the plan's build order); later slices flip the
  # pending domains below live one by one, each with its sanity pass.
  # Per-resource config (all optional): label, note, columns,
  # label_attr — the defaults introspect from the resource.
  @domains [
    %{
      key: :ops,
      label: "Ops",
      module: FluxVale.Ops,
      resources: [
        %{key: :feature_flag, module: FluxVale.Ops.FeatureFlag, config: %{}},
        %{
          key: :access_rule,
          module: FluxVale.Ops.AccessRule,
          config: %{
            # The FLAG mechanism (the plan's note config): honest copy
            # naming the constraint an operator trips on. Config copy,
            # not authored template copy — the copy line lives in
            # AdminResource's moduledoc.
            note:
              "Rows carry exactly one of domain or email, never both. They gate sign-in and the feedback board."
          }
        }
      ]
    }
  ]

  # The console's committed target (the plan's appendix A): the five
  # domains later slices roll out. Accounted for here so the parity
  # test holds the whole picture — a slice flips one live by moving it
  # into @domains above with its resource configs.
  @pending_domains [
    FluxVale.Catalog,
    FluxVale.Infrastructure,
    FluxVale.Pricing,
    FluxVale.Billing,
    FluxVale.Feedback
  ]

  # Excluded by name, each with its reason — the §3 posture carried
  # over from AshAdmin's exposure set (the plan's appendix A).
  @excluded_domains %{
    FluxVale.Identity =>
      "the auth surface: sessions, tokens, and credentials are not console data",
    FluxVale.Accounts =>
      "orgs and memberships belong to the curated orgs surfaces, not raw tables",
    FluxVale.Api => "machine-client bookkeeping (audit, rate windows), not operator data"
  }

  @doc """
  The live domains, in display order.
  """
  @spec domains() :: [domain()]
  def domains, do: @domains

  @doc """
  The later-slice domains (the parity test's seam — see @pending_domains).
  """
  @spec pending_domains() :: [module()]
  def pending_domains, do: @pending_domains

  @doc """
  The never-exposed domains with their documented reasons (the parity
  test's seam — see @excluded_domains).
  """
  @spec excluded_domains() :: %{module() => String.t()}
  def excluded_domains, do: @excluded_domains

  @doc """
  One live domain's resources. An unknown key answers [] — the mounts
  resolve unknown segments before this matters.
  """
  @spec resources(atom()) :: [resource()]
  def resources(domain_key) do
    case Enum.find(@domains, &(&1.key == domain_key)) do
      nil -> []
      %{resources: resources} -> resources
    end
  end

  @doc """
  Resolve a (domain, resource) pair to its registry entry. Segments
  arrive as URL strings — compared against the registry's existing
  atoms, never converted. Unknown anything answers :error (the caller
  bounces to the landing with an honest flash).
  """
  @type entry :: %{
          domain: %{key: atom(), label: String.t(), module: module()},
          key: atom(),
          module: module(),
          config: map()
        }

  @spec fetch(atom() | String.t(), atom() | String.t()) :: {:ok, entry()} | :error
  def fetch(domain_key, resource_key) do
    with {:ok, domain} <- by_key(@domains, domain_key),
         {:ok, resource} <- by_key(domain.resources, resource_key) do
      {:ok,
       %{
         domain: Map.take(domain, [:key, :label, :module]),
         key: resource.key,
         module: resource.module,
         config: resource.config
       }}
    end
  end

  @doc """
  May this actor run this action on this resource? `Ash.can?` with
  `maybe_is: true` — filter-shaped policies answer true and the
  dispatch stays honest, `:maybe` never hides a control the actor
  might run. The write surfaces (slice 2) gate every button on this.
  """
  @spec visible?(term(), module(), atom()) :: boolean()
  def visible?(actor, resource_module, action_name) do
    Ash.can?({resource_module, action_name}, actor, maybe_is: true)
  end

  # Lookup over existing registry atoms: atoms pass through, URL
  # strings compare against each entry's key spelled out. No atom is
  # ever created from input.
  defp by_key(entries, key) when is_atom(key) do
    case Enum.find(entries, &(&1.key == key)) do
      nil -> :error
      found -> {:ok, found}
    end
  end

  defp by_key(entries, key) when is_binary(key) do
    case Enum.find(entries, &(Atom.to_string(&1.key) == key)) do
      nil -> :error
      found -> {:ok, found}
    end
  end
end
