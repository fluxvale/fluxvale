defmodule FluxVale.Api.Operations.PruneAuditEventsTest do
  @moduledoc false

  # #360 slice 5: the retention sweep — rows older than the horizon
  # die, fresh ones stay. The janitor worker's own suite proves the
  # Oban wiring next door.

  use FluxVale.DataCase, async: true

  import Ecto.Query

  alias FluxVale.Api
  alias FluxVale.Api.AuditEvent
  alias FluxVale.Identity
  alias FluxVale.Identity.User
  alias FluxVale.Repo

  setup do
    user = User.create!("prune-audit@fluxvale.com", %{}, authorize?: false)

    {:ok, %{pat: pat}} =
      Identity.mint_pat(nil, %{user_id: user.id, name: "prune", scopes: []}, authorize?: false)

    %{pat: pat}
  end

  describe "call/1" do
    test "sweeps stale rows and keeps fresh ones", %{pat: pat} do
      # Seed-only state (house rule): actions stamp created_at at now
      # — a backdated row cannot be produced through them.
      Ash.Seed.seed!(AuditEvent, %{
        kind: :request,
        personal_access_token_id: pat.id,
        method: "GET",
        path: "/api/v1/me",
        status_code: 200,
        created_at: DateTime.add(DateTime.utc_now(), -91, :day)
      })

      assert :ok = Api.record_audit_event(%{kind: :request, personal_access_token_id: pat.id})

      # The stale request row dies; the fresh request row AND the
      # setup's mint row stay.
      assert {:ok, 1} = Api.prune_audit_events(authorize?: false)

      # Raw-table read: kinds come back as the stored text.
      remaining = remaining_kinds(pat.id)
      assert Enum.sort(remaining) == ["mint", "request"]
    end

    test "nothing stale is a quiet success" do
      assert {:ok, 0} = Api.prune_audit_events(authorize?: false)
    end
  end

  defp remaining_kinds(token_id) do
    query =
      from(e in "api_audit_events",
        select: e.kind,
        where: e.personal_access_token_id == type(^token_id, Ecto.UUID)
      )

    Repo.all(query)
  end
end
