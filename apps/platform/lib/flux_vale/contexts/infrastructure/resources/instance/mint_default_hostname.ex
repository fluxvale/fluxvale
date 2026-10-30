defmodule FluxVale.Infrastructure.Instance.MintDefaultHostname do
  @moduledoc """
  Puts the instance's default hostname in place at create (ADR-0040
  S1): find-or-create the org's `:platform` AccessDomain (the
  `instances_base_domain` row — one per org, `:verified` from birth
  because the fleet wildcard already covers it), then mint an
  `InstanceHostname` with `label = slug` on it. Runs AFTER
  `GenerateSlug` in the create chain: the label IS the slug.

  Find-or-create, not create: every instance of the org rides the SAME
  platform row. The unique identities — `(organization_id, domain)` on
  AccessDomain, `(access_domain_id, label)` on InstanceHostname — make
  a double-mint impossible: a race loses on the constraint, loudly,
  instead of forking a second row.

  Pure DB writes, no cluster calls — the instance create stays as
  reliable as it was before this change existed. The writes run
  `authorize?: false` inside the action's transaction: platform rows
  are system-minted (`:mint_platform` denies every actor) and the
  hostname's ownership is the instance's own — the create policy that
  admitted the actor has already gated THIS action, so re-checking the
  member's hand on these rows would only demand a policy no member
  holds. A failure here fails the create (the after_action's error
  rolls the whole transaction back) — an instance without its default
  hostname is not a created instance.
  """

  use Ash.Resource.Change

  alias FluxVale.Infrastructure.AccessDomain
  alias FluxVale.Infrastructure.InstanceHostname

  require Ash.Query

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, instance ->
      with {:ok, domain} <- platform_domain(instance.organization_id),
           {:ok, _hostname} <- mint_hostname(instance, domain) do
        {:ok, instance}
      end
    end)
  end

  # The org's platform row for the CURRENT base domain — find first so
  # every instance of the org serves off one row.
  defp platform_domain(organization_id) do
    base_domain = Application.fetch_env!(:flux_vale, :instances_base_domain)

    query =
      Ash.Query.filter(
        AccessDomain,
        organization_id == ^organization_id and kind == :platform and domain == ^base_domain
      )

    case Ash.read_one(query, authorize?: false) do
      {:ok, %AccessDomain{} = domain} ->
        {:ok, domain}

      {:ok, nil} ->
        AccessDomain.mint_platform(
          %{domain: base_domain, organization_id: organization_id},
          authorize?: false
        )

      # coveralls-ignore-start - defensive: DB read failure mid-create,
      # not simulatable under the sandbox (ExUnit cannot kill the DB)
      {:error, _reason} = error ->
        error

        # coveralls-ignore-stop
    end
  end

  defp mint_hostname(instance, domain) do
    InstanceHostname.mint(
      %{instance_id: instance.id, access_domain_id: domain.id, label: instance.slug},
      authorize?: false
    )
  end

  @impl Ash.Resource.Change
  # coveralls-ignore-next-line trivial callback — always false (writes another table)
  def atomic?, do: false
end
