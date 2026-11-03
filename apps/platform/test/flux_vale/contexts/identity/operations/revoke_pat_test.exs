defmodule FluxVale.Identity.Operations.RevokePatTest do
  @moduledoc false

  # #360: revocation is a policy-checked row write; the auth lookup
  # refuses a revoked row on the next presentation (the plug tests
  # prove that end-to-end).

  use FluxVale.DataCase, async: true

  alias FluxVale.Identity
  alias FluxVale.Identity.PersonalAccessToken
  alias FluxVale.Identity.User

  defp admin!(email \\ "revoke-admin@fluxvale.com") do
    case User.get_by_email(email, authorize?: false) do
      {:ok, existing} -> existing
      {:error, _not_found} -> User.create!(email, %{platform_role: :admin}, authorize?: false)
    end
  end

  defp member!(email), do: User.create!(email, %{}, authorize?: false)

  defp mint!(user_id, opts \\ []) do
    {:ok, %{pat: pat}} =
      Identity.mint_pat(
        nil,
        %{user_id: user_id, name: "test", scopes: ["instances:read"]},
        Keyword.put(opts, :authorize?, false)
      )

    pat
  end

  describe "call/3" do
    test "the owner revokes their own token" do
      member = member!("revoker@fluxvale.com")
      pat = mint!(member.id)

      assert {:ok, revoked} = Identity.revoke_pat(member, pat)
      assert revoked.revoked_at
    end

    test "a platform admin revokes a member's token — by record or by id" do
      member = member!("revoked@fluxvale.com")
      pat = mint!(member.id)

      assert {:ok, _revoked} = Identity.revoke_pat(admin!(), pat)

      other = mint!(member.id)
      assert {:ok, _revoked} = Identity.revoke_pat(admin!(), other.id)
    end

    test "idempotent: a second revoke keeps the original stamp" do
      member = member!("twice@fluxvale.com")
      pat = mint!(member.id)

      assert {:ok, first} = Identity.revoke_pat(member, pat)

      # The REVOKED record rides the second call — the arm that must
      # no-op, not a fresh read racing the same second's stamp.
      assert {:ok, second} = Identity.revoke_pat(member, first)
      assert second.revoked_at == first.revoked_at
    end

    test "a stranger sees neither the record nor its existence — by record and by id" do
      owner = member!("protect-owner@fluxvale.com")
      stranger = member!("protect-stranger@fluxvale.com")
      pat = mint!(owner.id)

      # Update policies forbid a non-owner's revoke outright…
      assert {:error, %Ash.Error.Forbidden{}} = Identity.revoke_pat(stranger, pat)

      # …and the by-id read FILTERS first (record-level read policies),
      # so the same stranger gets NotFound, not the row.
      assert {:error, %Ash.Error.Invalid{}} = Identity.revoke_pat(stranger, pat.id)
    end

    test "an unknown id is NotFound — existence stays hidden either way" do
      stranger = member!("no-such@fluxvale.com")

      # A random uuid matches nothing under the stranger's read filter
      # — indistinguishable from a real row they may not see.
      assert {:error, %Ash.Error.Invalid{}} =
               Identity.revoke_pat(stranger, Ash.UUID.generate())
    end

    test "list_for_user serves the owner's rows (the future panel's read)" do
      member = member!("lister@fluxvale.com")
      pat = mint!(member.id)

      assert {:ok, [row]} = PersonalAccessToken.list_for_user(member.id, actor: member)
      assert row.id == pat.id

      # Reads authorize by FILTERING: a stranger asking for someone
      # else's list gets their own (empty) view, never an error that
      # would confirm the rows exist.
      stranger = member!("lister-other@fluxvale.com")

      assert {:ok, []} = PersonalAccessToken.list_for_user(member.id, actor: stranger)
    end
  end
end
