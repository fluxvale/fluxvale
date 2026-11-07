defmodule FluxVale.Api.ScopesTest do
  @moduledoc false

  # The S1 scope catalog: what a token may hold (validate/1), what a
  # grant covers (grants?/2 — write implies read), and what each
  # /api/v1 route requires (required_scope/2 — the boundary plug and
  # the completeness test both ride this table).

  use FluxVale.DataCase, async: true

  alias FluxVale.Api.Scopes

  describe "valid_scope?/1" do
    test "every catalog entry is valid" do
      for scope <- Scopes.all_scopes() do
        assert Scopes.valid_scope?(scope)
      end
    end

    test "the catalog is exactly the S1 set — wallet and catalog are read-only" do
      assert Enum.sort(Scopes.all_scopes()) == [
               "backups:read",
               "backups:write",
               "catalog:read",
               "gateways:read",
               "gateways:write",
               "instances:read",
               "instances:write",
               "wallet:read"
             ]

      # write is NOT grantable for the read-only domains in S1
      refute Scopes.valid_scope?("wallet:write")
      refute Scopes.valid_scope?("catalog:write")
    end

    test "unknown domains and garbage are invalid" do
      refute Scopes.valid_scope?("admin")
      refute Scopes.valid_scope?("instances:admin")
      refute Scopes.valid_scope?("bogus:read")
      refute Scopes.valid_scope?("")
    end

    test "non-binary input is invalid, not an error (dirty-list guard)" do
      refute Scopes.valid_scope?(:instances)
      refute Scopes.valid_scope?(123)
      refute Scopes.valid_scope?(nil)
    end
  end

  describe "validate/1" do
    test "empty list is :ok (a scopeless token is a valid token)" do
      assert :ok = Scopes.validate([])
    end

    test "the full catalog is :ok" do
      assert :ok = Scopes.validate(Scopes.all_scopes())
    end

    test "off-catalog scopes are rejected with the offending value" do
      assert {:error, {:invalid_scope, "wallet:write"}} =
               Scopes.validate(["instances:read", "wallet:write"])

      assert {:error, {:invalid_scope, "nonsense"}} = Scopes.validate(["nonsense"])
    end

    test "duplicates are rejected with the repeated value" do
      assert {:error, {:duplicate_scope, "instances:read"}} =
               Scopes.validate(["instances:read", "backups:read", "instances:read"])
    end

    test "duplicates are reported before invalid entries" do
      assert {:error, {:duplicate_scope, "instances:read"}} =
               Scopes.validate(["instances:read", "instances:read", "bogus"])
    end
  end

  describe "grants?/2" do
    test "an exact grant covers its scope" do
      assert Scopes.grants?(["instances:read"], "instances:read")
    end

    test "write implies read for its domain" do
      assert Scopes.grants?(["instances:write"], "instances:read")
    end

    test "read does not imply write" do
      refute Scopes.grants?(["instances:read"], "instances:write")
    end

    test "a grant never crosses domains" do
      refute Scopes.grants?(["instances:write"], "backups:read")
      refute Scopes.grants?(["instances:read", "wallet:read"], "gateways:read")
    end

    test "no grants cover nothing beyond :any routes" do
      refute Scopes.grants?([], "instances:read")
    end
  end

  describe "required_scope/2" do
    test "scopeless routes answer :any" do
      assert {:ok, :any} = Scopes.required_scope("GET", ["me"])
      assert {:ok, :any} = Scopes.required_scope("GET", ["open_api"])

      # The actor's own orgs (#362 T6a) — membership IS the policy.
      assert {:ok, :any} = Scopes.required_scope("GET", ["organizations"])
    end

    test "instance routes" do
      assert {:ok, "instances:read"} = Scopes.required_scope("GET", ["instances"])
      assert {:ok, "instances:write"} = Scopes.required_scope("POST", ["instances"])
      assert {:ok, "instances:read"} = Scopes.required_scope("GET", ["instances", "abc"])

      for action <- ["deploy", "stop", "start", "always-on", "exposure"] do
        assert {:ok, "instances:write"} =
                 Scopes.required_scope("PATCH", ["instances", "abc", action])
      end

      assert {:ok, "instances:write"} = Scopes.required_scope("DELETE", ["instances", "abc"])
    end

    test "backup routes" do
      assert {:ok, "backups:read"} =
               Scopes.required_scope("GET", ["instances", "abc", "backup-setting"])

      assert {:ok, "backups:read"} =
               Scopes.required_scope("GET", ["instances", "abc", "backup-runs"])

      assert {:ok, "backups:write"} =
               Scopes.required_scope("POST", ["instances", "abc", "backup-setting"])

      assert {:ok, "backups:write"} =
               Scopes.required_scope("PATCH", ["backup-settings", "abc"])

      assert {:ok, "backups:write"} =
               Scopes.required_scope("DELETE", ["backup-settings", "abc"])

      assert {:ok, "backups:write"} =
               Scopes.required_scope("POST", ["instances", "abc", "backup-runs"])

      assert {:ok, "backups:write"} =
               Scopes.required_scope("POST", ["instances", "abc", "backup-runs", "r1", "restore"])
    end

    test "gateway routes" do
      assert {:ok, "gateways:read"} =
               Scopes.required_scope("GET", ["organizations", "org-1", "access-gateway"])

      assert {:ok, "gateways:write"} = Scopes.required_scope("POST", ["access-gateways"])

      assert {:ok, "gateways:write"} =
               Scopes.required_scope("PATCH", ["access-gateways", "g", "resume"])

      assert {:ok, "gateways:write"} =
               Scopes.required_scope("POST", ["access-gateways", "g", "attachments"])

      assert {:ok, "gateways:write"} =
               Scopes.required_scope("DELETE", ["access-gateways", "g", "attachments", "i"])
    end

    test "access-domain routes ride the gateways domain" do
      assert {:ok, "gateways:write"} = Scopes.required_scope("POST", ["access-domains"])

      assert {:ok, "gateways:read"} =
               Scopes.required_scope("GET", ["organizations", "org-1", "access-domains"])

      assert {:ok, "gateways:read"} = Scopes.required_scope("GET", ["access-domains", "d"])

      assert {:ok, "gateways:write"} =
               Scopes.required_scope("PATCH", ["access-domains", "d", "resume"])

      assert {:ok, "gateways:write"} = Scopes.required_scope("DELETE", ["access-domains", "d"])
    end

    test "wallet and catalog routes are read-only" do
      assert {:ok, "wallet:read"} = Scopes.required_scope("GET", ["organizations", "o", "wallet"])

      assert {:ok, "wallet:read"} =
               Scopes.required_scope("GET", ["organizations", "o", "wallet", "runway"])

      assert {:ok, "wallet:read"} =
               Scopes.required_scope("GET", ["wallets", "w", "ledger-entries"])

      assert {:ok, "catalog:read"} = Scopes.required_scope("GET", ["apps"])
      assert {:ok, "catalog:read"} = Scopes.required_scope("GET", ["apps", "x"])
      assert {:ok, "catalog:read"} = Scopes.required_scope("GET", ["apps", "x", "versions"])
      assert {:ok, "catalog:read"} = Scopes.required_scope("GET", ["app-versions", "v"])
    end

    test "the most specific pattern wins over a wildcard" do
      # Both ["instances", :_] and ["instances", :_, "backup-setting"]
      # match — the longer literal wins, and the answer is backups,
      # not instances.
      assert {:ok, "backups:read"} =
               Scopes.required_scope("GET", ["instances", "abc", "backup-setting"])

      # Same shape deeper: wallet/runway is wallet:read, not the
      # shorter organizations/:_/wallet rule's own scope via a
      # shorter match elsewhere.
      assert {:ok, "wallet:read"} =
               Scopes.required_scope("GET", ["organizations", "o", "wallet", "runway"])

      # app-versions/:id is its own row even though ["apps", :_]
      # cannot match (different literal).
      assert {:ok, "catalog:read"} = Scopes.required_scope("GET", ["app-versions", "v"])
    end

    test "unknown paths and methods are :error (deny by default)" do
      assert :error = Scopes.required_scope("GET", ["nope"])
      assert :error = Scopes.required_scope("GET", ["instances", "a", "b", "c"])
      assert :error = Scopes.required_scope("PATCH", ["me"])
      assert :error = Scopes.required_scope("GET", ["backup-settings", "x"])
      assert :error = Scopes.required_scope("POST", ["me"])
    end
  end
end
