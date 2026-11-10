defmodule FluxValeWeb.AdminAuditTest do
  @moduledoc false

  # The Audit section's browsable list (#645): its shape, its
  # registration truth, and the URL-resolution posture. The parity
  # seam with the doctrine gate's business set lives IN the gate
  # (test/flux_vale/admin_authority_test.exs) — one test both sides
  # must satisfy, so the section and the doctrine cannot drift.

  use FluxVale.DataCase, async: true

  alias Ash.Domain.Info
  alias FluxVale.Api.AuditEvent
  alias FluxVale.Billing.Wallet
  alias FluxVale.Billing.Wallet.Version
  alias FluxVale.Ops.FeatureFlag
  alias FluxValeWeb.AdminAudit

  describe "the entries" do
    test "one per business resource, keyed, labeled, and version-backed" do
      entries = AdminAudit.entries()

      assert length(entries) == 31

      keys = Enum.map(entries, & &1.key)
      assert Enum.uniq(keys) == keys, "entry keys must be unique"

      for entry <- entries do
        assert is_atom(entry.key)
        assert is_binary(entry.label) and entry.label != ""
        assert is_atom(entry.module)
        assert is_atom(entry.domain)

        # The Version module derives through the paper-trail
        # introspection, and the domain registers it — the section can
        # query it through the domain the way the doctrine gate does.
        version = AdminAudit.version_module(entry)
        assert version in Info.resources(entry.domain)
      end
    end

    test "registrations hold across the whole list" do
      assert AdminAudit.registrations_valid?()
    end
  end

  describe "URL resolution" do
    test "a known segment resolves against the existing atom, round trip" do
      for entry <- AdminAudit.entries() do
        segment = Atom.to_string(entry.key)
        assert {:ok, resolved} = AdminAudit.fetch(segment)
        assert resolved.key == entry.key
        assert resolved.module == entry.module
        assert resolved.domain == entry.domain
      end
    end

    test "an unknown segment answers :error — nothing is ever atomized" do
      assert AdminAudit.fetch("nope") == :error
      assert AdminAudit.fetch("no_such_resource_at_all") == :error

      # Resolution is exact: case and whitespace differences are just
      # unknown segments.
      assert AdminAudit.fetch("Wallet") == :error
      assert AdminAudit.fetch(" wallet ") == :error
    end

    test "a non-binary segment answers :error like any unknown" do
      assert AdminAudit.fetch(123) == :error
      assert AdminAudit.fetch(nil) == :error
    end
  end

  describe "module resolution" do
    test "a business-set module resolves to its entry key" do
      assert AdminAudit.key_for_module(FeatureFlag) == {:ok, :feature_flag}
      assert AdminAudit.key_for_module(Wallet) == {:ok, :wallet}
    end

    test "a module outside the business set answers :error" do
      assert AdminAudit.key_for_module(AuditEvent) == :error
      assert AdminAudit.key_for_module(Version) == :error
    end
  end
end
