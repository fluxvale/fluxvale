defmodule FluxVale.Ops.AccessRulesTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  alias FluxVale.Identity.User
  alias FluxVale.Identity.UserEmail
  alias FluxVale.Ops.AccessRule
  alias FluxVale.Ops.AccessRules

  # Test config runs the cache disabled (#26): allowed?/1 reads the table
  # directly in this process — instantly consistent, sandboxed, isolated
  # from every other async test's rows. The decision table is exercised
  # through both edges: decide/2 (the pure core) and allowed?/1.
  setup do
    # One real row through the action (repo convention); per-case shapes
    # are struct updates — decide/2 is the pure core, row shape is input.
    row = AccessRule.create!(%{domain: "fluxvale.com"}, authorize?: false)
    %{row: row}
  end

  defp rule(row, attrs), do: struct!(row, attrs)

  describe "decide/2 (the pure core)" do
    test "empty table = unrestricted — the mechanism's other face (#26)" do
      assert AccessRules.decide([], "anyone@example.com")
    end

    test "rows = allowlist: exact email matches", %{row: row} do
      email_row = rule(row, domain: nil, email: "someone@example.com")

      assert AccessRules.decide([email_row], "someone@example.com")
      assert AccessRules.decide([email_row], "SOMEONE@example.com")
      refute AccessRules.decide([email_row], "elsewhere@example.com")
    end

    test "rows = allowlist: exact domain matches", %{row: row} do
      assert AccessRules.decide([row], "anyone@fluxvale.com")
      assert AccessRules.decide([row], "ANYONE@FLUXVALE.COM")
      assert AccessRules.decide([rule(row, domain: "FluxVale.com")], "anyone@fluxvale.com")
      refute AccessRules.decide([row], "someone@example.com")
    end

    test "subdomains do not inherit — an exact domain is an exact domain", %{row: row} do
      refute AccessRules.decide([row], "someone@sub.fluxvale.com")
    end

    test "email and domain rows combine — one match admits", %{row: row} do
      email_row = rule(row, domain: nil, email: "invited@example.com")

      assert AccessRules.decide([row, email_row], "rando@fluxvale.com")
      assert AccessRules.decide([row, email_row], "invited@example.com")
      refute AccessRules.decide([row, email_row], "blocked@example.org")
    end
  end

  describe "allowed?/1 (the enforcement edge — reads the table in test)" do
    test "sees live rows: members in, outsiders out", %{row: _row} do
      assert AccessRules.allowed?("live-#{System.unique_integer()}@fluxvale.com")
      refute AccessRules.allowed?("outsider-#{System.unique_integer()}@example.com")
    end

    test "accepts ci_string input — callers hold Ash values, not strings" do
      address = Ash.CiString.new("ci-check@fluxvale.com")
      assert AccessRules.allowed?(address)
    end

    test "ensure_allowed/1 is unchanged at the address level" do
      assert :ok = AccessRules.ensure_allowed("live-#{System.unique_integer()}@fluxvale.com")
      assert {:error, :not_allowed} = AccessRules.ensure_allowed("out@example.com")
    end
  end

  describe "allowed?/2 — the purpose-aware edge (ADR-0026 §3)" do
    test ":feedback allowlists by email row, others out" do
      invited = "invited-#{System.unique_integer()}@example.com"
      AccessRule.create!(%{purpose: :feedback, email: invited}, authorize?: false)

      assert AccessRules.allowed?(:feedback, invited)
      refute AccessRules.allowed?(:feedback, "outsider-#{System.unique_integer()}@example.com")
    end

    test ":feedback allowlists by domain row" do
      AccessRule.create!(%{purpose: :feedback, domain: "invitees.example"}, authorize?: false)

      assert AccessRules.allowed?(:feedback, "anyone-#{System.unique_integer()}@invitees.example")
      refute AccessRules.allowed?(:feedback, "outsider-#{System.unique_integer()}@example.com")
    end

    test "an :auth row does not admit :feedback — disjoint allowlists" do
      AccessRule.create!(%{purpose: :auth, domain: "auths.example"}, authorize?: false)

      refute AccessRules.allowed?(:feedback, "someone-#{System.unique_integer()}@auths.example")
    end

    test ":auth keeps the staging/PAT semantics UNCHANGED — the pure core answers with no :auth rows in play",
         %{row: row} do
      # Hand-built row shape (decide/3 is pure — row shape is input): a
      # table holding ONLY :feedback rows is an empty AUTH table, and an
      # empty auth table is unrestricted entry.
      feedback_row = rule(row, domain: "invitees.example", purpose: :feedback)

      assert AccessRules.decide(:auth, [feedback_row], "anyone@example.org")
      refute AccessRules.allowed?(:feedback, "anyone-#{System.unique_integer()}@example.org")
    end

    test "an empty :feedback table allowlists NOBODY — an empty write-gate must not become an open gate" do
      # No :feedback rows in this test's sandbox.
      refute AccessRules.allowed?(:feedback, "anyone-#{System.unique_integer()}@example.com")
      refute AccessRules.decide(:feedback, [], "anyone@example.com")
    end

    test "the decision core filters by purpose before the emptiness call", %{row: row} do
      # Hand-built row shapes (decide/3 is pure — row shape is input):
      # an :auth-only table is an auth ALLOWLIST (exact matches only)
      # and admits nobody to the write gate.
      auth_row = rule(row, purpose: :auth)

      assert AccessRules.decide(:auth, [auth_row], "someone@fluxvale.com")
      refute AccessRules.decide(:auth, [auth_row], "someone@example.com")
      refute AccessRules.decide(:feedback, [auth_row], "someone@fluxvale.com")

      feedback_row = rule(row, domain: "invitees.example", purpose: :feedback)

      assert AccessRules.decide(:feedback, [feedback_row], "someone@invitees.example")
      assert AccessRules.decide(:auth, [feedback_row], "anyone@example.org")
    end
  end

  # The user-level gate (#285 T3): any VERIFIED address of the user
  # passing the allowlist keeps the account connected.
  describe "ensure_allowed_user/1 (#285 T3)" do
    defp user!(local) do
      User.create!("#{local}-#{System.unique_integer()}@example.com", %{}, authorize?: false)
    end

    defp add_verified!(user, address) do
      {:ok, row} = UserEmail.add(address, %{user: user}, authorize?: false)
      {:ok, _verified} = UserEmail.mark_verified(row, authorize?: false)
    end

    test "a user whose only verified address is allowlisted passes" do
      user =
        User.create!("gate-ok-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)

      assert :ok = AccessRules.ensure_allowed_user(user)
    end

    test "a user whose only verified address is de-allowlisted is severed" do
      user = user!("gate-out")

      assert {:error, :not_allowed} = AccessRules.ensure_allowed_user(user)
    end

    test "any allowlisted verified address keeps the user in — two addresses, one allowlisted" do
      user = user!("gate-two")
      add_verified!(user, "gate-two-b-#{System.unique_integer()}@fluxvale.com")

      assert :ok = AccessRules.ensure_allowed_user(user)
    end

    test "a pending claim never keeps the user connected — only verified rows count" do
      user = user!("gate-pending")

      {:ok, _pending} =
        UserEmail.add("gate-pending-b-#{System.unique_integer()}@fluxvale.com", %{user: user},
          authorize?: false
        )

      assert {:error, :not_allowed} = AccessRules.ensure_allowed_user(user)
    end

    test "a user with no verified address is severed — nothing proven, nothing granted" do
      # A user without user_emails rows is a state actions cannot produce
      # (the create mirror stamps one) — seed! is the sanctioned bypass.
      seeded =
        Ash.Seed.seed!(User, %{email: "gate-drift-#{System.unique_integer()}@example.com"})

      assert {:error, :not_allowed} = AccessRules.ensure_allowed_user(seeded)
    end
  end
end
