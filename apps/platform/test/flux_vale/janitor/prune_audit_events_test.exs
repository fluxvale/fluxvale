defmodule FluxVale.Janitor.PruneAuditEventsTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  import Ecto.Query

  alias FluxVale.Api.AuditEvent
  alias FluxVale.Identity
  alias FluxVale.Identity.User
  alias FluxVale.Janitor.PruneAuditEvents
  alias FluxVale.Repo

  describe "perform/1" do
    test "prunes stale audit events through the Api domain seam" do
      user = User.create!("janitor-audit@fluxvale.com", %{}, authorize?: false)

      {:ok, %{pat: pat}} =
        Identity.mint_pat(nil, %{user_id: user.id, name: "janitor", scopes: []},
          authorize?: false
        )

      # Seed-only state: a backdated row (see the operation's suite)
      Ash.Seed.seed!(AuditEvent, %{
        kind: :request,
        personal_access_token_id: pat.id,
        created_at: DateTime.add(DateTime.utc_now(), -91, :day)
      })

      # The cron-triggered entry point, exercised directly — the
      # business logic is Api.prune_audit_events/1 (own suite next door)
      assert {:ok, 1} = PruneAuditEvents.perform(%Oban.Job{})

      # The fresh mint row from the setup stays; only the stale one died.
      count_query =
        from(e in "api_audit_events",
          select: count(e.id),
          where: e.personal_access_token_id == type(^pat.id, Ecto.UUID)
        )

      assert Repo.one(count_query) == 1
    end
  end
end
