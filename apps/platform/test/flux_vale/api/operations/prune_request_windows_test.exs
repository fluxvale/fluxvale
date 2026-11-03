defmodule FluxVale.Api.Operations.PruneRequestWindowsTest do
  @moduledoc false

  # #360 slice 3: the retention sweep — windows older than the
  # horizon die, current ones stay. The janitor worker's own suite
  # proves the Oban wiring next door.

  use FluxVale.DataCase, async: true

  alias FluxVale.Api
  alias FluxVale.Api.RequestWindow
  alias FluxVale.Identity
  alias FluxVale.Identity.User
  alias FluxVale.Repo

  setup do
    user = User.create!("prune-windows@fluxvale.com", %{}, authorize?: false)

    mint! = fn name ->
      {:ok, %{pat: pat}} =
        Identity.mint_pat(nil, %{user_id: user.id, name: name, scopes: []}, authorize?: false)

      pat
    end

    %{mint!: mint!}
  end

  describe "call/1" do
    test "sweeps stale windows and keeps current ones", %{mint!: mint!} do
      stale_token = mint!.("stale")
      fresh_token = mint!.("fresh")

      # Seed-only state (house rule): the bump only ever writes the
      # CURRENT window — a backdated row cannot be produced through
      # actions. The fresh row rides the real bump.
      stale_window = ~U[2026-11-01 00:00:00Z]

      Ash.Seed.seed!(RequestWindow, %{
        token_id: stale_token.id,
        window_started_at: stale_window,
        count: 5_000
      })

      fresh_window = DateTime.utc_now(:second)
      Api.bump_request_window(fresh_token.id, fresh_window)

      assert {:ok, 1} = Api.prune_request_windows(authorize?: false)

      assert window_row?(stale_token.id, stale_window) == false
      assert window_row?(fresh_token.id, fresh_window) == true
    end

    test "an empty store is a quiet success" do
      assert {:ok, 0} = Api.prune_request_windows(authorize?: false)
    end
  end

  defp window_row?(token_id, window_started_at) do
    query =
      from(w in "request_windows",
        where:
          w.token_id == type(^token_id, Ecto.UUID) and
            w.window_started_at == type(^window_started_at, :utc_datetime)
      )

    Repo.exists?(query)
  end
end
