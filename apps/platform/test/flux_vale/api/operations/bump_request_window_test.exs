defmodule FluxVale.Api.Operations.BumpRequestWindowTest do
  @moduledoc false

  # #360 slice 3: the fixed-window counter store in isolation —
  # upsert-increment semantics, per-window and per-token keying. The
  # true-concurrency proof lives in bump_request_window_concurrency_test.

  use FluxVale.DataCase, async: true

  alias FluxVale.Api
  alias FluxVale.Identity
  alias FluxVale.Identity.User

  setup do
    user = User.create!("bump-window@fluxvale.com", %{}, authorize?: false)

    {:ok, %{pat: pat}} =
      Identity.mint_pat(nil, %{user_id: user.id, name: "bump test", scopes: []},
        authorize?: false
      )

    %{pat: pat}
  end

  describe "call/2" do
    test "first bump creates the window at 1, the second increments it", %{pat: pat} do
      window = ~U[2026-11-03 12:00:00Z]

      assert Api.bump_request_window(pat.id, window) == 1
      assert Api.bump_request_window(pat.id, window) == 2
      assert Api.bump_request_window(pat.id, window) == 3
    end

    test "a different window is a different counter — rollover keying", %{pat: pat} do
      first = ~U[2026-11-03 12:00:00Z]
      second = ~U[2026-11-03 12:01:00Z]

      Api.bump_request_window(pat.id, first)
      Api.bump_request_window(pat.id, first)

      # A new window starts from scratch — the exhausted old window
      # can never gate it (the plug's rollover guarantee).
      assert Api.bump_request_window(pat.id, second) == 1
    end

    test "a different token is a different counter — per-token keying", %{pat: pat} do
      other_owner = User.create!("bump-other@fluxvale.com", %{}, authorize?: false)

      {:ok, %{pat: other}} =
        Identity.mint_pat(nil, %{user_id: other_owner.id, name: "other", scopes: []},
          authorize?: false
        )

      window = ~U[2026-11-03 12:00:00Z]

      Api.bump_request_window(pat.id, window)
      Api.bump_request_window(pat.id, window)

      assert Api.bump_request_window(other.id, window) == 1
    end
  end
end
