defmodule FluxValeWeb.AdminAudit do
  @moduledoc """
  The Audit section's browsable resource list (#645, ADR-0048): one
  entry per business-set resource — the exact 31 the doctrine gate
  (test/flux_vale/admin_authority_test.exs) demands bypass AND trail
  on. The gate owns the set's definition and carries the parity seam:
  one test there asserts this module's audited module set equals the
  gate's business set, so the section and the doctrine cannot drift —
  a resource on either side alone is a red build.

  Each entry's Version module derives at runtime through the same
  paper-trail introspection the gate reads
  (`AshPaperTrail.Resource.Info.version_resource/1`), never a spelled
  module name — a version table the domain does not register cannot be
  named here.

  URL segments resolve against these entries' existing atoms — string
  compare, never `String.to_atom/1` on input (the console registry's
  rule, ADR-0027 §3). Unknown segments answer :error and the section
  bounces honestly.
  """

  alias Ash.Domain.Info

  @type entry :: %{
          key: atom(),
          label: String.t(),
          module: module(),
          domain: module()
        }

  # The business set, in the plan's table order (the gate's own
  # grouping). Keys are the registry's snake_case spelling; labels
  # derive per entries/0 the same way the console derives column
  # labels. Extending this list is the deliberate act the gate's
  # parity test forces.
  @entries [
    # Ops
    %{key: :feature_flag, module: FluxVale.Ops.FeatureFlag, domain: FluxVale.Ops},
    %{key: :access_rule, module: FluxVale.Ops.AccessRule, domain: FluxVale.Ops},
    # Catalog
    %{key: :category, module: FluxVale.Catalog.Category, domain: FluxVale.Catalog},
    %{key: :app, module: FluxVale.Catalog.App, domain: FluxVale.Catalog},
    %{key: :app_version, module: FluxVale.Catalog.AppVersion, domain: FluxVale.Catalog},
    # Infrastructure
    %{key: :cluster, module: FluxVale.Infrastructure.Cluster, domain: FluxVale.Infrastructure},
    %{key: :instance, module: FluxVale.Infrastructure.Instance, domain: FluxVale.Infrastructure},
    %{
      key: :backup_setting,
      module: FluxVale.Infrastructure.BackupSetting,
      domain: FluxVale.Infrastructure
    },
    %{
      key: :backup_run,
      module: FluxVale.Infrastructure.BackupRun,
      domain: FluxVale.Infrastructure
    },
    %{
      key: :access_gateway,
      module: FluxVale.Infrastructure.AccessGateway,
      domain: FluxVale.Infrastructure
    },
    %{
      key: :access_route,
      module: FluxVale.Infrastructure.AccessRoute,
      domain: FluxVale.Infrastructure
    },
    %{
      key: :access_domain,
      module: FluxVale.Infrastructure.AccessDomain,
      domain: FluxVale.Infrastructure
    },
    %{
      key: :instance_hostname,
      module: FluxVale.Infrastructure.InstanceHostname,
      domain: FluxVale.Infrastructure
    },
    %{
      key: :pocket_id_custody,
      module: FluxVale.Infrastructure.PocketIdCustody,
      domain: FluxVale.Infrastructure
    },
    %{
      key: :pocket_id_wiring,
      module: FluxVale.Infrastructure.PocketIdWiring,
      domain: FluxVale.Infrastructure
    },
    %{
      key: :storage_request,
      module: FluxVale.Infrastructure.StorageRequest,
      domain: FluxVale.Infrastructure
    },
    # Pricing
    %{key: :size, module: FluxVale.Pricing.Size, domain: FluxVale.Pricing},
    %{key: :tax_rate, module: FluxVale.Pricing.TaxRate, domain: FluxVale.Pricing},
    # Billing
    %{key: :wallet, module: FluxVale.Billing.Wallet, domain: FluxVale.Billing},
    %{key: :ledger_entry, module: FluxVale.Billing.LedgerEntry, domain: FluxVale.Billing},
    %{key: :topup, module: FluxVale.Billing.Topup, domain: FluxVale.Billing},
    # Feedback
    %{key: :post, module: FluxVale.Feedback.Post, domain: FluxVale.Feedback},
    %{key: :vote, module: FluxVale.Feedback.Vote, domain: FluxVale.Feedback},
    %{key: :comment, module: FluxVale.Feedback.Comment, domain: FluxVale.Feedback},
    %{key: :tag, module: FluxVale.Feedback.Tag, domain: FluxVale.Feedback},
    %{key: :post_tag, module: FluxVale.Feedback.PostTag, domain: FluxVale.Feedback},
    # Identity
    %{key: :user, module: FluxVale.Identity.User, domain: FluxVale.Identity},
    %{key: :user_email, module: FluxVale.Identity.UserEmail, domain: FluxVale.Identity},
    %{
      key: :personal_access_token,
      module: FluxVale.Identity.PersonalAccessToken,
      domain: FluxVale.Identity
    },
    # Accounts
    %{key: :organization, module: FluxVale.Accounts.Organization, domain: FluxVale.Accounts},
    %{key: :membership, module: FluxVale.Accounts.Membership, domain: FluxVale.Accounts},
    %{
      key: :membership_invite,
      module: FluxVale.Accounts.MembershipInvite,
      domain: FluxVale.Accounts
    }
  ]

  @doc """
  The audited resources, in display order. Labels derive from the keys
  the same way the console derives column labels — schema identifiers,
  not authored copy.
  """
  @spec entries() :: [entry()]
  def entries do
    Enum.map(@entries, fn entry ->
      %{
        key: entry.key,
        label: FluxValeWeb.AdminResource.label(entry.key),
        module: entry.module,
        domain: entry.domain
      }
    end)
  end

  @doc """
  Resolve a `?resource=` URL segment to its entry. The string compares
  against the entries' existing atoms and nothing else — unknown input
  answers :error, no atom is ever built from it.
  """
  @spec fetch(term()) :: {:ok, entry()} | :error
  def fetch(segment) when is_binary(segment) do
    case Enum.find(@entries, &(Atom.to_string(&1.key) == segment)) do
      nil -> :error
      found -> {:ok, materialize(found)}
    end
  end

  def fetch(_not_a_segment), do: :error

  @doc """
  The entry key for a resource module — the engine's show page uses it
  to build a record's audit History link. A module outside the
  business set answers :error (the link renders only where it
  resolves).
  """
  @spec key_for_module(module()) :: {:ok, atom()} | :error
  def key_for_module(module) do
    case Enum.find(@entries, &(&1.module == module)) do
      nil -> :error
      found -> {:ok, found.key}
    end
  end

  @doc """
  The entry's Version resource, derived through the paper-trail
  introspection the doctrine gate reads — never a spelled module name.
  """
  @spec version_module(entry()) :: module()
  def version_module(entry) do
    AshPaperTrail.Resource.Info.version_resource(entry.module)
  end

  defp materialize(entry) do
    %{
      key: entry.key,
      label: FluxValeWeb.AdminResource.label(entry.key),
      module: entry.module,
      domain: entry.domain
    }
  end

  @doc """
  True when every entry's Version module is registered in its entry's
  domain (the parity arm's runtime half — the gate asserts the same
  through its own list).
  """
  @spec registrations_valid?() :: boolean()
  def registrations_valid? do
    Enum.all?(entries(), fn entry ->
      version = version_module(entry)
      Enum.member?(Info.resources(entry.domain), version)
    end)
  end
end
