defmodule FluxVale.Ops.InvitedEmailTest do
  @moduledoc false

  use FluxVale.DataCase, async: true
  use Mimic

  import FluxVale.TestSupport.InvitationHelpers

  alias FluxVale.Identity.User
  alias FluxVale.Ops.InvitedEmail

  # Ash.Query.filter is a macro
  require Ash.Query

  setup do
    %{admin: admin(), regular: regular_user()}
  end

  # Preconditions run authorize?: false (repo convention — mirrors the
  # seeds bootstrap); the policy itself is what's under test below.
  defp admin do
    case User.get_by_email("admin@fluxvale.com", authorize?: false) do
      {:ok, existing} ->
        existing

      {:error, _not_found} ->
        User.create!("admin@fluxvale.com", %{platform_role: :admin}, authorize?: false)
    end
  end

  defp regular_user do
    User.create!("regular-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
  end

  describe "create/2 (adding IS the invite)" do
    test "records the address and sends the invitation email", %{admin: admin} do
      address = "newcomer-#{System.unique_integer()}@partner.example"

      assert {:ok, %InvitedEmail{revoked_at: nil} = invited} =
               InvitedEmail
               |> Ash.Changeset.for_create(:create, %{address: address}, actor: admin)
               |> Ash.create(authorize?: true)

      assert to_string(invited.address) == address

      assert_receive {:email, %Swoosh.Email{} = mail}, 1_000
      assert mail.to == [{"", address}]
      assert mail.subject =~ "invited"
      assert mail.text_body =~ "invitation-only"
      assert mail.text_body =~ "https://fluxvale.com"
    end

    test "the address is the credential: case-insensitive uniqueness" do
      address = "dup-#{System.unique_integer()}@partner.example"
      invite_address!(address)
      upcased = String.upcase(address)

      assert {:error, _taken} =
               InvitedEmail
               |> Ash.Changeset.for_create(:create, %{address: upcased}, authorize?: false)
               |> Ash.create(authorize?: false)

      drain_mail!()
    end

    test "a malformed address is refused at the cast" do
      assert {:error, _invalid} =
               InvitedEmail
               |> Ash.Changeset.for_create(:create, %{address: "not-an-address"},
                 authorize?: false
               )
               |> Ash.create(authorize?: false)
    end

    test "a failed delivery does not fail the create (the row is the credential)" do
      Mimic.copy(FluxVale.Mailer)
      stub(FluxVale.Mailer, :deliver_invitation, fn _to -> {:error, :smtp_down} end)

      address = "bounced-#{System.unique_integer()}@partner.example"

      assert {:ok, %InvitedEmail{}} =
               InvitedEmail
               |> Ash.Changeset.for_create(:create, %{address: address}, authorize?: false)
               |> Ash.create(authorize?: false)
    end
  end

  describe "revoke" do
    test "stamps revoked_at and sends no email" do
      invited = invite_address!("revoke-#{System.unique_integer()}@partner.example")
      drain_mail!()

      revoked = revoke!(invited)

      refute is_nil(revoked.revoked_at)
      refute_received {:email, %Swoosh.Email{}}
    end

    test "is idempotent: the first stamp survives a re-revoke" do
      invited = invite_address!("rerevoke-#{System.unique_integer()}@partner.example")
      drain_mail!()
      first = revoke!(invited)

      second =
        first
        |> Ash.Changeset.for_update(:revoke, %{}, authorize?: false)
        |> Ash.update!(authorize?: false)

      assert second.revoked_at == first.revoked_at
    end
  end

  describe "policy (ADR-0027: mutations ride ActorIsPlatformAdmin)" do
    test "the admin adds an invite — the AshAdmin path", %{admin: admin} do
      address = "admin-invited-#{System.unique_integer()}@partner.example"

      assert {:ok, %InvitedEmail{}} =
               InvitedEmail
               |> Ash.Changeset.for_create(:create, %{address: address}, actor: admin)
               |> Ash.create(authorize?: true)

      drain_mail!()
    end

    test "non-admins are denied everything, default-deny", %{regular: regular} do
      address = "denied-#{System.unique_integer()}@partner.example"

      assert {:error, %Ash.Error.Forbidden{}} =
               InvitedEmail
               |> Ash.Changeset.for_create(:create, %{address: address}, actor: regular)
               |> Ash.create(authorize?: true)

      # a precondition row created on the system seam: the regular actor
      # must not read it, revoke it, or add anything of their own
      invite_address!(address)
      invited = invitation(address)

      assert {:error, %Ash.Error.Forbidden{}} =
               invited
               |> Ash.Changeset.for_update(:revoke, %{}, actor: regular)
               |> Ash.update(authorize?: true)

      assert {:error, %Ash.Error.Forbidden{}} =
               InvitedEmail
               |> Ash.Query.filter(address == ^address)
               |> Ash.read(actor: regular, authorize?: true)
    end
  end
end
