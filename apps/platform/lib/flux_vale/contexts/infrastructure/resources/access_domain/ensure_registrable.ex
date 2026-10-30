defmodule FluxVale.Infrastructure.AccessDomain.EnsureRegistrable do
  @moduledoc """
  The registration boundaries (review round 1): a member's `:register`
  may claim a domain only if it is registrable at all —

  - FluxVale's OWN serving domain (`instances_base_domain`) is never a
    custom registration. It exists as per-org `:platform` rows by
    design; issuing a customer Certificate for it would fight the fleet
    wildcard that already covers it.
  - the domain must not exist anywhere as a `:custom` row. Custom
    domains are platform-wide unique to FluxVale: two orgs must never
    hold Certificates for the same dnsName (Let's Encrypt would prove
    one org's control of the other's name). The
    `access_domains_custom_domain_unique` partial index is the race
    backstop — a double-mint loses on the constraint, loudly; this
    probe is the friendly front door for the common case.

  The probe reads across orgs `authorize?: false` — a uniqueness check
  is a write concern, not an exposure (the GenerateSlug stance): the
  caller is entitled to know the name is taken, and org-scoping the
  read would make the check meaningless. It runs in the register
  action's transaction (a before_action), so the probe and the insert
  see one consistent table.
  """

  use Ash.Resource.Change

  alias FluxVale.Infrastructure.AccessDomain

  require Ash.Query

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      domain = Ash.Changeset.get_attribute(changeset, :domain)

      cond do
        # coveralls-ignore-next-line - defensive: :domain is cast (or
        # rejected "is required"/"is invalid") before changes run, so a
        # before_action hook never sees a non-binary value on a valid
        # changeset — the arm only guards a future writer force-setting
        # junk past the cast.
        not is_binary(domain) ->
          changeset

        platform_domain?(domain) ->
          Ash.Changeset.add_error(
            changeset,
            field: :domain,
            message: "FluxVale's own domain cannot be registered"
          )

        taken?(domain) ->
          Ash.Changeset.add_error(
            changeset,
            field: :domain,
            message: "is already registered"
          )

        true ->
          changeset
      end
    end)
  end

  defp platform_domain?(domain) do
    domain == Application.fetch_env!(:flux_vale, :instances_base_domain)
  end

  # The cross-org uniqueness probe (see the moduledoc for the
  # authorize?: false stance).
  defp taken?(domain) do
    AccessDomain
    |> Ash.Query.filter(domain == ^domain and kind == :custom)
    |> Ash.exists?(authorize?: false)
  end

  @impl Ash.Resource.Change
  # coveralls-ignore-next-line trivial callback — always false (reads another table)
  def atomic?, do: false
end
