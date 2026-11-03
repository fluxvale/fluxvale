defmodule FluxVale.Janitor.PruneRequestWindowsTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  alias FluxVale.Api.RequestWindow
  alias FluxVale.Identity
  alias FluxVale.Identity.User
  alias FluxVale.Janitor.PruneRequestWindows
  alias FluxVale.Repo

  describe "perform/1" do
    test "prunes stale request windows through the Api domain seam" do
      user = User.create!("janitor-windows@fluxvale.com", %{}, authorize?: false)

      {:ok, %{pat: pat}} =
        Identity.mint_pat(nil, %{user_id: user.id, name: "janitor", scopes: []},
          authorize?: false
        )

      # Seed-only state: a backdated window (see the operation's suite)
      Ash.Seed.seed!(RequestWindow, %{
        token_id: pat.id,
        window_started_at: DateTime.add(DateTime.utc_now(), -2, :day),
        count: 42
      })

      # The cron-triggered entry point, exercised directly — the
      # business logic is Api.prune_request_windows/1 (own suite next
      # door)
      assert {:ok, 1} = PruneRequestWindows.perform(%Oban.Job{})

      gone? = from(w in "request_windows", where: w.token_id == type(^pat.id, Ecto.UUID))
      assert Repo.exists?(gone?) == false
    end
  end
end
