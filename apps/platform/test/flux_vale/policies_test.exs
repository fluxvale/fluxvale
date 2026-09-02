defmodule FluxVale.PoliciesTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias FluxVale.Policies

  describe "platform_admin?/1" do
    test "an admin user passes" do
      assert Policies.platform_admin?(%{platform_role: :admin})
    end

    test "a regular user does not" do
      refute Policies.platform_admin?(%{platform_role: :user})
    end

    test "no actor is never admin" do
      refute Policies.platform_admin?(nil)
    end

    test "records without a platform role are not admin" do
      refute Policies.platform_admin?(%{})
    end
  end
end
