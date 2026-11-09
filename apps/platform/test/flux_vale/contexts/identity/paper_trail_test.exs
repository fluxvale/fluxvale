defmodule FluxVale.Identity.PaperTrailTest do
  @moduledoc false

  # The audit-trail proof on Identity (#645, the plan's A2-S3 slice):
  # invites/reinvites/withdrawals and renames attribute to their
  # actors, PAT mint/revoke attribute to the owner, the sensitive
  # token hashes redact everywhere including the unchanged-marker case
  # (decision one, ADR-0048), and sign-in writes NO User versions —
  # the observed truth (sign-in touches Token and AuthCode, both
  # machinery, unversioned). Mirrors the Billing suite (the A2-S2
  # exemplar).

  use FluxVale.DataCase, async: true

  alias FluxVale.Identity.PersonalAccessToken
  alias FluxVale.Identity.User
  alias FluxVale.Identity.UserEmail
  alias FluxVale.TestSupport.AccountsFixtures

  require Ash.Query

  defp versions!(version_module, source_id) do
    version_module
    |> Ash.Query.filter(version_source_id == ^source_id)
    |> Ash.Query.sort(version_inserted_at: :asc)
    |> Ash.read!(authorize?: false)
  end

  describe "invites and renames attribute to their actors" do
    test "an admin invite versions with the admin actor, the hash redacted" do
      admin = AccountsFixtures.platform_admin!()
      address = "pt-invite-#{System.unique_integer([:positive])}@fluxvale.test"

      {:ok, invited, _raw} =
        FluxVale.Identity.invite_user(admin, address, fn _to, _url -> {:ok, :sent} end)

      [version] = versions!(User.Version, invited.id)

      assert version.version_action_name == :invite
      assert version.user_id == admin.id
      assert version.actor_label == admin.username

      # Decision one (ADR-0048): the sensitive hash reads REDACTED in
      # the changes, and no raw value rides the action inputs.
      assert version.changes["invite_token_hash"] == "REDACTED"
      assert Map.get(version.version_action_inputs, "invite_token_hash") in [nil, "REDACTED"]
    end

    test "a reinvite and a withdraw version with the admin actor, the hash redacted unchanged" do
      admin = AccountsFixtures.platform_admin!()
      address = "pt-reinvite-#{System.unique_integer([:positive])}@fluxvale.test"

      {:ok, invited, _raw} =
        FluxVale.Identity.invite_user(admin, address, fn _to, _url -> {:ok, :sent} end)

      {:ok, _invited, _raw2} =
        FluxVale.Identity.invite_user(admin, address, fn _to, _url -> {:ok, :sent} end)

      {:ok, _withdrawn} = FluxVale.Identity.withdraw_invite(admin, invited.id)

      versions = versions!(User.Version, invited.id)
      names = Enum.map(versions, & &1.version_action_name)

      assert names == [:invite, :reinvite, :withdraw_invite]
      assert Enum.all?(versions, &(&1.user_id == admin.id))

      reinvite = Enum.at(versions, 1)

      # The unchanged-marker case (decision one): the reinvite writes a
      # fresh hash, but the redaction quirk means the hash key shows
      # REDACTED regardless — the marker says the attribute exists and
      # is protected, not that it moved.
      assert reinvite.changes["invite_token_hash"] == "REDACTED"

      withdraw = Enum.at(versions, 2)

      # The withdraw touches no hash at all — yet the changes still
      # carry the REDACTED marker for it. This is the pinned quirk.
      assert withdraw.changes["invite_token_hash"] == "REDACTED"
      assert withdraw.changes["invite_withdrawn_at"]
    end

    test "a user's set_username versions with that user" do
      user = AccountsFixtures.user!()

      user
      |> Ash.Changeset.for_update(
        :set_username,
        %{username: "pt-rename-#{System.unique_integer([:positive])}"},
        actor: user
      )
      |> Ash.update!()

      [create_version, rename_version] = versions!(User.Version, user.id)

      assert rename_version.version_action_name == :set_username
      assert rename_version.user_id == user.id
      assert rename_version.actor_label == user.username
      assert create_version.changes["invite_token_hash"] == "REDACTED"
    end
  end

  describe "personal access tokens attribute and redact" do
    test "a self-minted PAT versions its owner; a revoke versions; touches never do" do
      user = AccountsFixtures.user!()

      {:ok, %{pat: pat, token: _raw}} =
        FluxVale.Identity.mint_pat(user, %{user_id: user.id, name: "pt-proof", scopes: []})

      [create_version] = versions!(PersonalAccessToken.Version, pat.id)

      assert create_version.version_action_name == :create
      assert create_version.user_id == user.id

      # Decision one: the hash is REDACTED in the changes; the raw
      # value exists only in the mint's return, never in the trail.
      assert create_version.changes["token_hash"] == "REDACTED"
      assert Map.get(create_version.version_action_inputs, "token_hash") in [nil, "REDACTED"]

      # The auth path stamps last_used_at per request — decision two
      # silenced it: two system touches write ZERO version rows.
      {:ok, _touched_once} = PersonalAccessToken.touch_last_used(pat, authorize?: false)
      {:ok, _touched_twice} = PersonalAccessToken.touch_last_used(pat, authorize?: false)

      assert length(versions!(PersonalAccessToken.Version, pat.id)) == 1

      {:ok, _revoked} =
        pat
        |> Ash.Changeset.for_update(:revoke, %{}, actor: user)
        |> Ash.update()

      [_create_version, revoke_version] = versions!(PersonalAccessToken.Version, pat.id)

      assert revoke_version.version_action_name == :revoke
      assert revoke_version.user_id == user.id

      # The revoke writes no hash — the REDACTED marker rides anyway
      # (the unchanged-marker case, pinned).
      assert revoke_version.changes["token_hash"] == "REDACTED"
    end
  end

  describe "sign-in and the atomic state write (observed, pinned)" do
    test "a sign-in writes NO User versions" do
      email = "pt-signin-#{System.unique_integer([:positive])}@fluxvale.test"
      user = User.create!(email, %{}, authorize?: false)

      before = versions!(User.Version, user.id)

      :ok =
        FluxVale.Identity.request_auth_code(email, fn _to, code ->
          send(self(), {:pt_code, code})
          {:ok, nil}
        end)

      assert_receive {:pt_code, code}, 1_000

      {:ok, _user, _token} = FluxVale.Identity.verify_auth_code(email, code)

      # Observed truth: sign-in burns an AuthCode and mints a Token —
      # both machinery, both unversioned. The User row stays untouched.
      assert versions!(User.Version, user.id) == before
    end

    test "an atomic-capable state update stores empty inputs (observed)" do
      user = AccountsFixtures.user!()

      email_row =
        UserEmail
        |> Ash.Changeset.for_create(
          :add,
          %{
            address: "pt-email-#{System.unique_integer([:positive])}@fluxvale.test",
            user: %{id: user.id}
          },
          authorize?: false
        )
        |> Ash.create!()

      email_row
      |> Ash.Changeset.for_update(:mark_verified, %{}, authorize?: false)
      |> Ash.update!()

      [add_version, verify_version] = versions!(UserEmail.Version, email_row.id)

      assert add_version.version_action_name == :add
      assert add_version.version_action_inputs["address"]

      # mark_verified is atomic-capable (no require_atomic? false, no
      # function changes) — the A2-S1 finding's shape on the no-input
      # path: the inputs map is empty, the changes carry the true value.
      assert verify_version.version_action_name == :mark_verified
      assert verify_version.version_action_inputs == %{}
      assert verify_version.changes["verified_at"]
    end
  end
end
