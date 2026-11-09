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

  alias Ash.Resource.Info

  @type domain :: %{
          key: atom(),
          label: String.t(),
          module: module(),
          resources: [resource()]
        }
  @type resource :: %{key: atom(), module: module(), config: map()}

  # Live domains in display order, each with its resources. Slices 1-2
  # proved the engine on Ops; slice 3 rolls Pricing and Billing live
  # (the plan's sanity pass 1). Later slices flip the pending domains
  # below one by one. Per-resource config (all optional): label, note,
  # columns, label_attr — the defaults introspect from the resource.
  # A domain's out-of-console resources live in @excluded_resources
  # below, keyed by the domain MODULE — never a key on the domain map.
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
    },
    %{
      key: :pricing,
      label: "Pricing",
      module: FluxVale.Pricing,
      resources: [
        %{key: :size, module: FluxVale.Pricing.Size, config: %{}},
        %{
          key: :tax_rate,
          module: FluxVale.Pricing.TaxRate,
          config: %{label_attr: :country}
        }
      ]
    },
    %{
      key: :billing,
      label: "Billing",
      module: FluxVale.Billing,
      resources: [
        %{
          key: :wallet,
          module: FluxVale.Billing.Wallet,
          config: %{
            note:
              "Creates and ladder state are system-only. The curated wallets and billing section is the daily tool; this surface exposes the paywall waiver.",
            create_actions: [:create],
            update_actions: [:set_carryover, :set_ladder_state]
          }
        },
        %{
          key: :ledger_entry,
          module: FluxVale.Billing.LedgerEntry,
          config: %{
            note:
              "Append-only ledger. Goodwill credits post here; the curated billing section owns the daily view and reversals ride the curated wallet surface.",
            create_actions: [:create, :reverse]
          }
        }
      ]
    }
  ]

  # The console's committed target (the plan's appendix A): the three
  # domains later slices roll out. Accounted for here so the parity
  # test holds the whole picture — a slice flips one live by moving it
  # into @domains above with its resource configs.
  @pending_domains [
    FluxVale.Catalog,
    FluxVale.Infrastructure,
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

  # Resources excluded by name from otherwise-live domains, keyed by
  # the domain module, each with its reason. Two exclusion kinds ride
  # here today: the paper-trail version tables (#645 — the audit trail
  # surfaces in its own console section as a cross-resource view, not
  # one raw table per resource) and operator-absent resources
  # (Billing's Topup: gateway-driven rows, the payment gateway owns
  # every write). Every entry needs its reason — the parity test
  # enforces it.
  @excluded_resources %{
    FluxVale.Billing => %{
      FluxVale.Billing.Topup =>
        "gateway-driven rows: the payment gateway owns every write, an operator has no path here"
    },
    FluxVale.Ops => %{
      FluxVale.Ops.FeatureFlag.Version =>
        "the paper-trail version table: the Audit section surfaces it, not the generic console (#645)",
      FluxVale.Ops.AccessRule.Version =>
        "the paper-trail version table: the Audit section surfaces it, not the generic console (#645)"
    }
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
  One live domain's resources excluded by name, each with its
  documented reason (the parity test's seam — see @excluded_resources).
  """
  @spec excluded_resources(module()) :: %{module() => String.t()}
  def excluded_resources(domain), do: Map.get(@excluded_resources, domain, %{})

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
  might run. The write surfaces gate every button on this.
  """
  @spec visible?(term(), module(), atom()) :: boolean()
  def visible?(actor, resource_module, action_name) do
    Ash.can?({resource_module, action_name}, actor, maybe_is: true)
  end

  @doc """
  The resource's actions of one write type the registry permits: the
  resource's own actions minus the config's exclusion list (the plan's
  registry-intent gate — machinery actions like Instance's `perform_*`
  never render, no matter what the policy would say). `?action=` and
  every button resolve against this list and nothing else.
  """
  @spec allowed_actions(module(), :create | :update | :destroy, map()) :: [map()]
  def allowed_actions(resource_module, type, config) do
    excluded = config[exclusion_key(type)] || []

    resource_module
    |> Info.actions()
    |> Enum.filter(&(&1.type == type and &1.name not in excluded))
  end

  # The write-type config keys, one per type (the plan's exclusion
  # lists: create_actions / update_actions / destroy_actions).
  defp exclusion_key(:create), do: :create_actions
  defp exclusion_key(:update), do: :update_actions
  defp exclusion_key(:destroy), do: :destroy_actions

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
