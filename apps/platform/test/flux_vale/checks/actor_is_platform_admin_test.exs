defmodule FluxVale.Checks.ActorIsPlatformAdminTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias FluxVale.Checks.ActorIsPlatformAdmin

  describe "platform_admin?/1" do
    test "an admin user passes" do
      assert ActorIsPlatformAdmin.platform_admin?(%{platform_role: :admin})
    end

    test "a regular user does not" do
      refute ActorIsPlatformAdmin.platform_admin?(%{platform_role: :user})
    end

    test "no actor is never admin" do
      refute ActorIsPlatformAdmin.platform_admin?(nil)
    end

    test "records without a platform role are not admin" do
      refute ActorIsPlatformAdmin.platform_admin?(%{})
    end
  end

  describe "describe/1" do
    test "states the question it answers" do
      assert ActorIsPlatformAdmin.describe([]) == "actor is a platform admin"
    end
  end
end
