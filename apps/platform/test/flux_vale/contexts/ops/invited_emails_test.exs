defmodule FluxVale.Ops.InvitedEmailsTest do
  @moduledoc """
  The invitation semantics (#478): the team bypass, the per-address
  matching (a second address at an invited domain is still refused),
  revocation, and the parse-garbage arms.
  """

  use FluxVale.DataCase, async: true

  import FluxVale.TestSupport.InvitationHelpers

  alias FluxVale.Ops.InvitedEmails

  describe "allows?/1 — the team bypass" do
    test "any @fluxvale.com address is admitted, no row needed" do
      assert InvitedEmails.allows?("anyone@fluxvale.com")
      assert InvitedEmails.allows?("Anyone@fluxvale.com")
      assert InvitedEmails.allows?("terence+ea@FLUXVALE.COM")
    end

    test "lookalikes are not the bypass" do
      refute InvitedEmails.allows?("someone@mail.fluxvale.com")
      refute InvitedEmails.allows?("someone@notfluxvale.com")
      refute InvitedEmails.allows?("someone@fluxvale.com.evil.example")
    end
  end

  describe "allows?/1 — per-address invitations" do
    test "the invited address is admitted, case-insensitively" do
      invited = "Alice-#{System.unique_integer()}@Partner.Example"
      invite_address!(invited)

      lower = String.downcase(invited)
      upper = String.upcase(invited)
      assert InvitedEmails.allows?(lower)
      assert InvitedEmails.allows?(upper)
    end

    test "a second address at the same domain is still refused (never per domain)" do
      unique = System.unique_integer()
      invite_address!("alice-#{unique}@partner.example")

      refute InvitedEmails.allows?("bob-#{unique}@partner.example")
    end

    test "an address with no invitation anywhere is refused" do
      refute InvitedEmails.allows?("stranger-#{System.unique_integer()}@elsewhere.example")
    end

    test "a revoked invite admits nothing" do
      invited = invite_address!("revoke-me-#{System.unique_integer()}@partner.example")
      drain_mail!()
      address = to_string(invited.address)

      assert InvitedEmails.allows?(address)
      revoke!(invited)

      upcased = String.upcase(address)
      refute InvitedEmails.allows?(address)
      refute InvitedEmails.allows?(upcased)
    end
  end

  describe "allows?/1 — garbage in, false out" do
    test "nil is refused" do
      refute InvitedEmails.allows?(nil)
    end

    test "an address with no @ is refused" do
      refute InvitedEmails.allows?("no-at-sign")
    end
  end
end
