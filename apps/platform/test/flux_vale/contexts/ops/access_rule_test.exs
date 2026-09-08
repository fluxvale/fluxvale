defmodule FluxVale.Ops.AccessRuleTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  alias FluxVale.Identity.User
  alias FluxVale.Ops.AccessRule

  # Preconditions run authorize?: false (repo convention — mirrors the seeds
  # bootstrap); the policy itself is what's under test below.
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

  describe "create/2" do
    test "accepts a domain row and an email row — the two ADR-0023 shapes" do
      assert {:ok, %AccessRule{email: nil} = domain_row} =
               AccessRule.create(%{domain: "fluxvale.com"}, authorize?: false)

      assert to_string(domain_row.domain) == "fluxvale.com"

      assert {:ok, %AccessRule{domain: nil}} =
               AccessRule.create(
                 %{email: "invited-#{System.unique_integer()}@example.com"},
                 authorize?: false
               )
    end

    test "requires exactly one of domain/email — neither is inert, both is ambiguous" do
      assert {:error, %Ash.Error.Invalid{}} =
               AccessRule.create(%{}, authorize?: false)

      assert {:error, %Ash.Error.Invalid{}} =
               AccessRule.create(
                 %{
                   domain: "fluxvale.com",
                   email: "someone@example.com"
                 },
                 authorize?: false
               )
    end

    test "rejects rows that could never match an address domain" do
      assert {:error, %Ash.Error.Invalid{}} =
               AccessRule.create(%{domain: "not a domain"}, authorize?: false)
    end

    test "enforces unique rows per shape" do
      AccessRule.create!(%{domain: "fluxvale.com"}, authorize?: false)

      assert {:error, %Ash.Error.Invalid{}} =
               AccessRule.create(%{domain: "fluxvale.com"}, authorize?: false)

      # citext both directions: uniqueness is case-insensitive too
      # (CodeRabbit, #48 — a differently-cased duplicate is integrity rot)
      assert {:error, %Ash.Error.Invalid{}} =
               AccessRule.create(%{domain: "FluxVale.com"}, authorize?: false)

      AccessRule.create!(%{email: "one@example.com"}, authorize?: false)

      assert {:error, %Ash.Error.Invalid{}} =
               AccessRule.create(%{email: "one@example.com"}, authorize?: false)
    end
  end

  describe "policy (ADR-0027: mutations ride ActorIsPlatformAdmin)" do
    setup do
      %{admin: admin(), regular: regular_user()}
    end

    test "non-admins are denied everything, default-deny", %{regular: regular} do
      rule = AccessRule.create!(%{domain: "fluxvale.com"}, authorize?: false)

      assert {:error, %Ash.Error.Forbidden{}} =
               AccessRule.create(%{domain: "example.com"}, actor: regular, authorize?: true)

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.update(rule, %{domain: "other.com"}, actor: regular, authorize?: true)

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.destroy(rule, actor: regular, authorize?: true)

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.read(AccessRule, actor: regular, authorize?: true)

      # Anonymous browsing AshAdmin sees nothing either
      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.read(AccessRule, authorize?: true)
    end

    test "admins create, tighten, and remove — the paths AshAdmin rides", %{admin: admin} do
      assert {:ok, rule} =
               AccessRule.create(%{domain: "fluxvale.com"}, actor: admin, authorize?: true)

      # Tightening: swap the domain row for an exact email row (the old
      # value must be explicitly cleared — present([:domain, :email],
      # exactly: 1) sees the carried-over domain otherwise)
      assert {:ok, tightened} =
               Ash.update(rule, %{domain: nil, email: "one@example.com"}, actor: admin)

      assert is_nil(tightened.domain)

      assert {:ok, [_row]} = Ash.read(AccessRule, actor: admin, authorize?: true)
      assert :ok = Ash.destroy(tightened, actor: admin, authorize?: true)
    end
  end
end
