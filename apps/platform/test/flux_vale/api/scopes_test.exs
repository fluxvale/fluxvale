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
               "organizations:read",
               "organizations:write",
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
      assert {:ok, :any} = Scopes.required_scope("GET", ["pricing", "quote"])
    end

    test "organization routes ride the organizations domain" do
      assert {:ok, "organizations:read"} = Scopes.required_scope("GET", ["organizations"])
      assert {:ok, "organizations:write"} = Scopes.required_scope("POST", ["organizations"])

      assert {:ok, "organizations:read"} =
               Scopes.required_scope("GET", ["organizations", "by-slug", "acme"])

      assert {:ok, "organizations:read"} =
               Scopes.required_scope("GET", ["organizations", "org-1"])

      assert {:ok, "organizations:write"} =
               Scopes.required_scope("PATCH", ["organizations", "org-1"])

      assert {:ok, "organizations:write"} =
               Scopes.required_scope("DELETE", ["organizations", "org-1"])

      # Write implies read; read never implies write.
      assert Scopes.grants?(["organizations:write"], "organizations:read")
      refute Scopes.grants?(["organizations:read"], "organizations:write")
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

    test "storage-request routes ride the instances domain" do
      assert {:ok, "instances:write"} =
               Scopes.required_scope("POST", ["instances", "abc", "storage-requests"])

      assert {:ok, "instances:read"} =
               Scopes.required_scope("GET", ["instances", "abc", "storage-requests"])

      assert {:ok, "instances:read"} =
               Scopes.required_scope("GET", ["storage-requests", "req-1"])
    end

    test "custom-hostname routes ride the instances domain" do
      assert {:ok, "instances:write"} =
               Scopes.required_scope("POST", ["instances", "i", "hostnames"])

      assert {:ok, "instances:read"} =
               Scopes.required_scope("GET", ["instances", "i", "hostnames"])

      assert {:ok, "instances:write"} =
               Scopes.required_scope("DELETE", ["instance-hostnames", "h"])
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

  describe "domains/0" do
    test "one entry per domain, in catalog order" do
      keys = Enum.map(Scopes.domains(), & &1.key)

      assert keys == ["instances", "backups", "gateways", "wallet", "catalog", "organizations"]
    end

    test "each entry carries the domain, its key, and a capitalized label" do
      for domain <- Scopes.domains() do
        assert Atom.to_string(domain.domain) == domain.key
        assert domain.label == String.capitalize(domain.key)
      end
    end

    test "wallet and catalog are read-only: no write scope or write description" do
      for domain <- Scopes.domains(), domain.key in ["wallet", "catalog"] do
        refute domain.writable?
        assert domain.write_scope == nil
        assert domain.write_description == nil
        assert domain.read_scope == "#{domain.key}:read"
        assert domain.read_description == Scopes.describe(domain.read_scope)
      end
    end

    test "the writable domains carry both scopes with real descriptions" do
      writable = Enum.filter(Scopes.domains(), & &1.writable?)

      assert Enum.map(writable, & &1.key) == ["instances", "backups", "gateways", "organizations"]

      for domain <- writable do
        assert domain.write_scope == "#{domain.key}:write"
        assert domain.write_description == Scopes.describe(domain.write_scope)
        assert domain.read_description == Scopes.describe(domain.read_scope)
      end
    end

    test "the union of domain scopes equals the flat catalog" do
      domain_scopes =
        Enum.flat_map(Scopes.domains(), fn domain ->
          Enum.reject([domain.read_scope, domain.write_scope], &is_nil/1)
        end)

      assert Enum.sort(domain_scopes) == Enum.sort(Scopes.all_scopes())
    end

    test "every catalog scope carries a real description" do
      for scope <- Scopes.all_scopes() do
        assert Scopes.describe(scope) != scope
      end
    end
  end

  describe "default_levels/0" do
    test "every domain key starts at none" do
      assert Scopes.default_levels() == %{
               "instances" => "none",
               "backups" => "none",
               "gateways" => "none",
               "wallet" => "none",
               "catalog" => "none",
               "organizations" => "none"
             }
    end
  end

  describe "scopes_for_level/2" do
    test "none expands to no scopes on any domain" do
      assert {:ok, []} = Scopes.scopes_for_level("instances", "none")
      assert {:ok, []} = Scopes.scopes_for_level("wallet", "none")
    end

    test "read expands to the domain's read scope" do
      assert {:ok, ["instances:read"]} = Scopes.scopes_for_level("instances", "read")
    end

    test "write on a writable domain expands to read and write" do
      assert {:ok, ["instances:read", "instances:write"]} =
               Scopes.scopes_for_level("instances", "write")
    end

    test "write on a read-only domain is rejected" do
      assert {:error, {:invalid_scope, "wallet:write"}} =
               Scopes.scopes_for_level("wallet", "write")

      assert {:error, {:invalid_scope, "catalog:write"}} =
               Scopes.scopes_for_level("catalog", "write")
    end

    test "an unknown domain is rejected" do
      assert {:error, {:invalid_scope, "bogus:read"}} = Scopes.scopes_for_level("bogus", "read")
    end

    test "an unknown level is rejected" do
      assert {:error, {:invalid_scope, "instances:admin"}} =
               Scopes.scopes_for_level("instances", "admin")
    end

    test "non-binary input is rejected with the inspected pair" do
      non_binary_domain = Enum.at([123], 0)
      non_binary_level = Enum.at([123], 0)

      assert {:error, {:invalid_scope, "123:\"read\""}} =
               Scopes.scopes_for_level(non_binary_domain, "read")

      assert {:error, {:invalid_scope, "\"instances\":123"}} =
               Scopes.scopes_for_level("instances", non_binary_level)
    end
  end

  describe "scopes_for_levels/1" do
    test "an empty map expands to no scopes" do
      assert {:ok, []} = Scopes.scopes_for_levels(%{})
    end

    test "all none expands to no scopes" do
      assert {:ok, []} = Scopes.scopes_for_levels(Scopes.default_levels())
    end

    test "a mixed selection expands in catalog order" do
      assert {:ok, scopes} =
               Scopes.scopes_for_levels(%{
                 "instances" => "write",
                 "wallet" => "read",
                 "organizations" => "write"
               })

      assert scopes == [
               "instances:read",
               "instances:write",
               "wallet:read",
               "organizations:read",
               "organizations:write"
             ]
    end

    test "a write level on a read-only domain fails closed" do
      assert {:error, {:invalid_scope, _scope}} = Scopes.scopes_for_levels(%{"wallet" => "write"})
    end

    test "an unknown domain key fails closed" do
      assert {:error, {:invalid_scope, _scope}} = Scopes.scopes_for_levels(%{"bogus" => "read"})
    end

    test "an unknown level fails closed" do
      assert {:error, {:invalid_scope, _scope}} =
               Scopes.scopes_for_levels(%{"instances" => "admin"})
    end

    test "a non-map input is rejected" do
      non_map = Enum.at([["nope"]], 0)

      assert {:error, {:invalid_scope, "invalid"}} = Scopes.scopes_for_levels(non_map)
    end
  end
end
