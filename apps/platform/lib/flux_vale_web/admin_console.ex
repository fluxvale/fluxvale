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
  # proved the engine on Ops; slice 3 rolled Pricing and Billing live;
  # slice 4 rolled Catalog; slice 5 rolled Infrastructure (the plan's
  # sanity passes and the policy proof); slice 6 rolls Feedback, the
  # last domain — nothing is pending. Per-resource config (all
  # optional): label, note, columns, label_attr — the defaults
  # introspect from the resource. A domain's out-of-console resources
  # live in @excluded_resources below, keyed by the domain MODULE —
  # never a key on the domain map.
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
    },
    %{
      key: :catalog,
      label: "Catalog",
      module: FluxVale.Catalog,
      resources: [
        %{key: :category, module: FluxVale.Catalog.Category, config: %{}},
        %{
          key: :app,
          module: FluxVale.Catalog.App,
          config: %{
            label_attr: :name,
            columns: [:name, :category_id],
            note:
              "The catalog page and its deploy wizard are the daily tool. This raw surface carries the marketing copy fields the page renders."
          }
        },
        %{
          key: :app_version,
          module: FluxVale.Catalog.AppVersion,
          config: %{
            columns: [:version, :app_id, :published_at],
            label_attr: :version,
            note:
              "Blueprint rows for deploy. The curated catalog surgery surfaces (#540 lane) stay the daily tool for promote/retire flows."
          }
        }
      ]
    },
    %{
      key: :infrastructure,
      label: "Infrastructure",
      module: FluxVale.Infrastructure,
      resources: [
        %{key: :cluster, module: FluxVale.Infrastructure.Cluster, config: %{}},
        %{
          key: :instance,
          module: FluxVale.Infrastructure.Instance,
          config: %{
            label_attr: :name,
            columns: [:organization_id, :name, :app_version_id, :status, :exposure, :cluster_id],
            status_attrs: [:status],
            update_actions: [
              :perform_deploy,
              :perform_reconcile,
              :perform_settle,
              :settle_anchors,
              :perform_teardown,
              :merge_pocket_id_env,
              :mark_deploy_error,
              :mark_teardown_error
            ],
            note:
              "The curated instance page and the catalog deploy wizard are the daily tool. This raw surface carries the lifecycle writes; the system's deploy, settle and teardown machinery never renders. env_vars is sensitive (bundled credentials included) and renders verbatim on the show page — treat it as a secret."
          }
        },
        %{
          key: :instance_allocation_snapshot,
          module: FluxVale.Infrastructure.InstanceAllocationSnapshot,
          config: %{
            columns: [:id],
            create_actions: [:record],
            update_actions: [:supersede],
            note:
              "Allocation telemetry: one row per allocation era, superseded and appended by a resize. Read-only here, the instance page and billing own the live view."
          }
        },
        %{
          key: :backup_setting,
          module: FluxVale.Infrastructure.BackupSetting,
          config: %{label_attr: :endpoint}
        },
        %{
          key: :backup_run,
          module: FluxVale.Infrastructure.BackupRun,
          config: %{
            create_actions: [:create],
            update_actions: [:update],
            note:
              "Backup history is written by the backup machinery. The instance page owns the run and restore actions."
          }
        },
        %{
          key: :access_gateway,
          module: FluxVale.Infrastructure.AccessGateway,
          config: %{
            label_attr: :hostname,
            columns: [:organization_id, :hostname, :tailnet_domain, :state, :monthly_cents],
            status_attrs: [:state],
            create_actions: [:create],
            update_actions: [
              :update_state,
              :set_api_token_ref,
              :update_claims,
              :perform_observe,
              :perform_provision,
              :perform_settle,
              :settle_anchors,
              :perform_teardown,
              :mark_provision_error,
              :mark_teardown_error
            ],
            destroy_actions: [:destroy_after_teardown],
            note:
              "The curated access page owns gateway enablement and its status panel. This surface carries the credential recovery and suspend/resume writes."
          }
        },
        %{
          key: :access_route,
          module: FluxVale.Infrastructure.AccessRoute,
          config: %{
            label_attr: :route_key,
            create_actions: [:create],
            destroy_actions: [:destroy],
            note:
              "Routes are minted by the attach path; the gateway page owns them. Read-only here."
          }
        },
        %{
          key: :access_domain,
          module: FluxVale.Infrastructure.AccessDomain,
          config: %{
            label_attr: :domain,
            create_actions: [:mint_platform],
            update_actions: [:mark_verified, :mark_failed, :mark_needs_attention, :mark_suspended],
            note:
              "Register and resume are the operator writes; the observed issuance states are the system's. The domains surface owns the daily view."
          }
        },
        %{
          key: :instance_hostname,
          module: FluxVale.Infrastructure.InstanceHostname,
          config: %{
            label_attr: :label,
            create_actions: [:mint],
            destroy_actions: [:destroy],
            note: "Hostnames are minted by the instance paths. Read-only here."
          }
        }
      ]
    },
    %{
      key: :feedback,
      label: "Feedback",
      module: FluxVale.Feedback,
      resources: [
        %{
          key: :post,
          module: FluxVale.Feedback.Post,
          config: %{
            label_attr: :title,
            columns: [:title, :status, :vote_count, :comment_count, :organization_id],
            badge_relationships: [:tags],
            update_actions: [:bump_vote_count, :bump_comment_count],
            note:
              "The public board and the moderation surface are the daily tools. This surface carries the moderation writes: content edits, status, tags and destroy."
          }
        },
        %{
          key: :vote,
          module: FluxVale.Feedback.Vote,
          config: %{
            columns: [:post_id, :organization_id, :cast_by_user_id],
            note:
              "Votes are cast and retracted by board users. This surface acts as the platform admin, so a cast here is the admin's own vote."
          }
        },
        %{
          key: :comment,
          module: FluxVale.Feedback.Comment,
          config: %{
            columns: [:post_id, :body, :author_user_id],
            note:
              "Comments here are authored as the platform admin. The board and the moderation surface own the public view."
          }
        },
        %{
          key: :tag,
          module: FluxVale.Feedback.Tag,
          config: %{
            label_attr: :name,
            columns: [:name, :slug],
            note:
              "The curated vocabulary: create, rename and remove tags here. Posts pick tags through their set_tags action."
          }
        },
        %{
          key: :post_tag,
          module: FluxVale.Feedback.PostTag,
          config: %{
            columns: [:post_id, :tag_id],
            note:
              "Tagging is curated from the post page via set_tags. This raw join surface is for data surgery only."
          }
        }
      ]
    }
  ]

  # The console's committed target (the plan's appendix A): the domains
  # later slices roll out. Accounted for here so the parity test holds
  # the whole picture — a slice flips one live by moving it into
  # @domains above with its resource configs. Slice 6 rolled the last
  # one (Feedback), so no domain is pending.
  @pending_domains []

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
      FluxVale.Billing.Wallet.Version =>
        "the paper-trail version table: the Audit section surfaces it, not the generic console (#645)",
      FluxVale.Billing.LedgerEntry.Version =>
        "the paper-trail version table: the Audit section surfaces it, not the generic console (#645)",
      FluxVale.Billing.Topup =>
        "gateway-driven rows: the payment gateway owns every write, an operator has no path here",
      FluxVale.Billing.Topup.Version =>
        "the paper-trail version table: the Audit section surfaces it, not the generic console (#645)"
    },
    FluxVale.Pricing => %{
      FluxVale.Pricing.Size.Version =>
        "the paper-trail version table: the Audit section surfaces it, not the generic console (#645)",
      FluxVale.Pricing.TaxRate.Version =>
        "the paper-trail version table: the Audit section surfaces it, not the generic console (#645)"
    },
    FluxVale.Catalog => %{
      FluxVale.Catalog.Category.Version =>
        "the paper-trail version table: the Audit section surfaces it, not the generic console (#645)",
      FluxVale.Catalog.App.Version =>
        "the paper-trail version table: the Audit section surfaces it, not the generic console (#645)",
      FluxVale.Catalog.AppVersion.Version =>
        "the paper-trail version table: the Audit section surfaces it, not the generic console (#645)"
    },
    FluxVale.Feedback => %{
      FluxVale.Feedback.Post.Version =>
        "the paper-trail version table: the Audit section surfaces it, not the generic console (#645)",
      FluxVale.Feedback.Vote.Version =>
        "the paper-trail version table: the Audit section surfaces it, not the generic console (#645)",
      FluxVale.Feedback.Comment.Version =>
        "the paper-trail version table: the Audit section surfaces it, not the generic console (#645)",
      FluxVale.Feedback.Tag.Version =>
        "the paper-trail version table: the Audit section surfaces it, not the generic console (#645)",
      FluxVale.Feedback.PostTag.Version =>
        "the paper-trail version table: the Audit section surfaces it, not the generic console (#645)"
    },
    FluxVale.Ops => %{
      FluxVale.Ops.FeatureFlag.Version =>
        "the paper-trail version table: the Audit section surfaces it, not the generic console (#645)",
      FluxVale.Ops.AccessRule.Version =>
        "the paper-trail version table: the Audit section surfaces it, not the generic console (#645)"
    },
    FluxVale.Infrastructure => %{
      FluxVale.Infrastructure.Cluster.Version =>
        "the paper-trail version table: the Audit section surfaces it, not the generic console (#645)",
      FluxVale.Infrastructure.Instance.Version =>
        "the paper-trail version table: the Audit section surfaces it, not the generic console (#645)",
      FluxVale.Infrastructure.BackupSetting.Version =>
        "the paper-trail version table: the Audit section surfaces it, not the generic console (#645)",
      FluxVale.Infrastructure.BackupRun.Version =>
        "the paper-trail version table: the Audit section surfaces it, not the generic console (#645)",
      FluxVale.Infrastructure.AccessGateway.Version =>
        "the paper-trail version table: the Audit section surfaces it, not the generic console (#645)",
      FluxVale.Infrastructure.AccessRoute.Version =>
        "the paper-trail version table: the Audit section surfaces it, not the generic console (#645)",
      FluxVale.Infrastructure.AccessDomain.Version =>
        "the paper-trail version table: the Audit section surfaces it, not the generic console (#645)",
      FluxVale.Infrastructure.InstanceHostname.Version =>
        "the paper-trail version table: the Audit section surfaces it, not the generic console (#645)",
      FluxVale.Infrastructure.PocketIdCustody.Version =>
        "the paper-trail version table: the Audit section surfaces it, not the generic console (#645)",
      FluxVale.Infrastructure.StorageRequest.Version =>
        "the paper-trail version table: the Audit section surfaces it, not the generic console (#645)",
      FluxVale.Infrastructure.PocketIdCustody =>
        "the PocketID SSO machinery (#597): the curated SSO card and wiring operations own these rows",
      FluxVale.Infrastructure.PocketIdCustodyEvent =>
        "the PocketID SSO machinery (#597): the wiring operations write these event rows",
      FluxVale.Infrastructure.PocketIdWiring =>
        "the PocketID SSO machinery (#597): the curated SSO card and wiring operations own this row",
      FluxVale.Infrastructure.PocketIdWiring.Version =>
        "the paper-trail version table: the Audit section surfaces it, not the generic console (#645)",
      FluxVale.Infrastructure.StorageRequest =>
        "the curated storage-request queue (ADR-0046 D5) owns this workflow; the raw table stays out"
    },
    FluxVale.Identity => %{
      FluxVale.Identity.User.Version =>
        "the paper-trail version table: the Audit section surfaces it, not the generic console (#645)",
      FluxVale.Identity.UserEmail.Version =>
        "the paper-trail version table: the Audit section surfaces it, not the generic console (#645)",
      FluxVale.Identity.PersonalAccessToken.Version =>
        "the paper-trail version table: the Audit section surfaces it, not the generic console (#645)"
    },
    FluxVale.Accounts => %{
      FluxVale.Accounts.Organization.Version =>
        "the paper-trail version table: the Audit section surfaces it, not the generic console (#645)",
      FluxVale.Accounts.Membership.Version =>
        "the paper-trail version table: the Audit section surfaces it, not the generic console (#645)",
      FluxVale.Accounts.MembershipInvite.Version =>
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
      {:ok, build_entry(domain, resource.module)}
    end
  end

  @doc """
  Resolve a resource module to its registry entry (the FK-link seam:
  a belongs_to whose destination is a live registry resource links to
  its show page; everything else renders as a plain uuid).
  """
  @spec fetch_by_module(module()) :: {:ok, entry()} | :error
  def fetch_by_module(module) do
    case Enum.find(@domains, &Enum.any?(&1.resources, fn r -> r.module == module end)) do
      nil -> :error
      domain -> {:ok, build_entry(domain, module)}
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

  # The entry shape shared by fetch/2 and fetch_by_module/1 — one
  # construction, so the two seams can never drift.
  defp build_entry(domain, module) do
    resource = Enum.find(domain.resources, &(&1.module == module))

    %{
      domain: Map.take(domain, [:key, :label, :module]),
      key: resource.key,
      module: resource.module,
      config: resource.config
    }
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
