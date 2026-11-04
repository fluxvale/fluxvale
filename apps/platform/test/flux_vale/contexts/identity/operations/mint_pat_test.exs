defmodule FluxVale.Identity.Operations.MintPatTest do
  @moduledoc false

  # #360: the scoped-PAT mint. The raw value exists only in the return
  # (asserted against logs below); the row carries the SHA-256 hash and
  # nothing recoverable.

  use FluxVale.DataCase, async: true

  import ExUnit.CaptureLog

  alias FluxVale.Identity
  alias FluxVale.Identity.PersonalAccessToken
  alias FluxVale.Identity.User

  defp admin!(email \\ "mint-admin@fluxvale.com") do
    case User.get_by_email(email, authorize?: false) do
      {:ok, existing} -> existing
      {:error, _not_found} -> User.create!(email, %{platform_role: :admin}, authorize?: false)
    end
  end

  defp member!(email), do: User.create!(email, %{}, authorize?: false)

  describe "call/3" do
    test "an admin mints a scoped PAT for a member — raw value returned once" do
      member = member!("minted@fluxvale.com")

      assert {:ok, %{token: raw, pat: pat}} =
               Identity.mint_pat(admin!(), %{
                 user_id: member.id,
                 name: "cli laptop",
                 scopes: ["instances:read", "backups:write"]
               })

      assert raw =~ ~r/^fvpat_[A-Za-z0-9_-]{43}$/
      assert pat.user_id == member.id
      assert pat.name == "cli laptop"
      assert pat.scopes == ["instances:read", "backups:write"]

      # Only the hash is stored: the row's token_hash is the digest of
      # the raw value — and nothing else in the row can reproduce it.
      assert pat.token_hash == PersonalAccessToken.token_hash(raw)
      assert pat.token_hash != raw
      assert byte_size(pat.token_hash) == 64

      assert {:ok, row} =
               PersonalAccessToken.get_by_token_hash(pat.token_hash, authorize?: false)

      assert row.token_hash == PersonalAccessToken.token_hash(raw)
    end

    test "expires_at defaults to one year out; an explicit value wins" do
      member = member!("expiry@fluxvale.com")
      before_mint = DateTime.utc_now()

      assert {:ok, %{pat: pat}} =
               Identity.mint_pat(admin!(), %{user_id: member.id, name: "a", scopes: []})

      assert_in_delta DateTime.diff(pat.expires_at, before_mint), 365 * 24 * 60 * 60, 5

      explicit = DateTime.add(DateTime.utc_now(), 3600, :second)

      assert {:ok, %{pat: short}} =
               Identity.mint_pat(admin!(), %{user_id: member.id, name: "b", expires_at: explicit})

      # :utc_datetime stores second precision — the attribute type's
      # contract, not a mint defect.
      assert short.expires_at == DateTime.truncate(explicit, :second)
    end

    test "metadata defaults to an empty map; a passed record lands verbatim (#362's provenance)" do
      member = member!("metadata@fluxvale.com")

      assert {:ok, %{pat: bare}} =
               Identity.mint_pat(admin!(), %{user_id: member.id, name: "bare", scopes: []})

      assert bare.metadata == %{}

      provenance = %{
        "client_id" => "fluxvale-cli",
        "grant_type" => "device_flow",
        "scopes" => ["instances:read"],
        "minted_via" => "device"
      }

      assert {:ok, %{pat: pat}} =
               Identity.mint_pat(admin!(), %{
                 user_id: member.id,
                 name: "provenance",
                 scopes: ["instances:read"],
                 metadata: provenance
               })

      assert pat.metadata == provenance
    end

    test "metadata is operation-supplied — the create action's accept surface can't stamp it" do
      member = member!("metadata-guard@fluxvale.com")

      # The token_hash shape verbatim: the argument is private, so a
      # caller that bypasses the operation cannot stamp provenance.
      changeset =
        PersonalAccessToken
        |> Ash.Changeset.new()
        |> Ash.Changeset.set_argument(:token_hash, PersonalAccessToken.token_hash("fvpat_x"))
        |> Ash.Changeset.for_create(:create, %{
          user_id: member.id,
          name: "forged",
          expires_at: DateTime.add(DateTime.utc_now(), 60, :second),
          metadata: %{"minted_via" => "forged"}
        })

      assert {:error, %Ash.Error.Invalid{}} = Ash.create(changeset, authorize?: false)
    end

    test "a far-future explicit expires_at is capped at the one-year bound" do
      member = member!("far-future@fluxvale.com")
      before_mint = DateTime.utc_now()
      beyond = DateTime.add(DateTime.utc_now(), 10 * 365 * 24 * 60 * 60, :second)

      assert {:ok, %{pat: pat}} =
               Identity.mint_pat(admin!(), %{
                 user_id: member.id,
                 name: "decade",
                 expires_at: beyond
               })

      # The documented worst case holds: the bound, never the ask.
      assert_in_delta DateTime.diff(pat.expires_at, before_mint), 365 * 24 * 60 * 60, 5
    end

    test "a user mints their own PAT (self-service shape)" do
      member = member!("self@fluxvale.com")

      assert {:ok, %{pat: pat}} =
               Identity.mint_pat(member, %{
                 user_id: member.id,
                 name: "mine",
                 scopes: ["wallet:read"]
               })

      assert pat.user_id == member.id
    end

    test "the audit log names the ids, never the raw value" do
      member = member!("audited@fluxvale.com")

      # The suite runs at :warning (config/test.exs), so the info line
      # needs the level opened for this test and restored after.
      previous = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous) end)

      {result, log} =
        with_log(fn ->
          Identity.mint_pat(admin!(), %{user_id: member.id, name: "x", scopes: []})
        end)

      assert {:ok, %{token: raw, pat: pat}} = result
      assert log =~ "PAT minted: user=#{member.id}"
      assert log =~ "token=#{pat.id}"
      refute log =~ raw
      refute log =~ "fvpat_"
    end

    test "off-catalog scopes are refused before anything is created" do
      member = member!("bad-scope@fluxvale.com")

      assert {:error, {:invalid_scope, "wallet:write"}} =
               Identity.mint_pat(admin!(), %{
                 user_id: member.id,
                 name: "x",
                 scopes: ["wallet:write"]
               })

      assert {:error, {:duplicate_scope, "instances:read"}} =
               Identity.mint_pat(admin!(), %{
                 user_id: member.id,
                 name: "x",
                 scopes: ["instances:read", "instances:read"]
               })

      assert [] = PersonalAccessToken.list_for_user!(member.id, authorize?: false)
    end
  end

  describe "the create policy" do
    test "a non-admin cannot mint for someone else" do
      member = member!("cross@fluxvale.com")
      other = member!("crossed@fluxvale.com")

      assert {:error, %Ash.Error.Forbidden{}} =
               Identity.mint_pat(member, %{user_id: other.id, name: "theft", scopes: []})
    end

    test "no actor is forbidden under authorization" do
      member = member!("nil-actor@fluxvale.com")

      assert {:error, %Ash.Error.Forbidden{}} =
               Identity.mint_pat(nil, %{user_id: member.id, name: "x", scopes: []},
                 authorize?: true
               )
    end

    test "the operator path mints without an actor (IEx/e2e posture)" do
      member = member!("operator@fluxvale.com")

      assert {:ok, %{token: _raw, pat: pat}} =
               Identity.mint_pat(nil, %{user_id: member.id, name: "e2e", scopes: []},
                 authorize?: false
               )

      assert pat.user_id == member.id
    end
  end

  describe "the audit trail (#360 slice 5)" do
    test "a mint appends an audit row naming the operator" do
      admin = admin!("mint-auditor@fluxvale.com")
      member = member!("mint-audited@fluxvale.com")

      assert {:ok, %{pat: pat}} =
               Identity.mint_pat(admin, %{user_id: member.id, name: "audited", scopes: []})

      assert [%{kind: :mint} = row] = audit_rows(pat.id)

      assert row.personal_access_token_id == pat.id
      assert row.actor_id == admin.id

      # No HTTP shape on a lifecycle row.
      assert row.method == nil
      assert row.path == nil
      assert row.status_code == nil
    end

    test "the no-actor operator path records a nil actor" do
      member = member!("mint-noactor@fluxvale.com")

      assert {:ok, %{pat: pat}} =
               Identity.mint_pat(nil, %{user_id: member.id, name: "op", scopes: []},
                 authorize?: false
               )

      assert [%{kind: :mint} = row] = audit_rows(pat.id)
      assert row.actor_id == nil
    end
  end

  describe "the resource-level catalog guard" do
    # The operation validates first; the resource guard is what stops a
    # caller that bypasses it — same invariant, second door.
    test "a direct create with off-catalog scopes is invalid" do
      member = member!("guard@fluxvale.com")

      changeset =
        PersonalAccessToken
        |> Ash.Changeset.new()
        |> Ash.Changeset.set_argument(:token_hash, PersonalAccessToken.token_hash("fvpat_x"))
        |> Ash.Changeset.for_create(:create, %{
          user_id: member.id,
          name: "x",
          expires_at: DateTime.add(DateTime.utc_now(), 60, :second),
          scopes: ["instances:admin"]
        })

      assert {:error, %Ash.Error.Invalid{}} = Ash.create(changeset, authorize?: false)
    end

    test "a direct create with duplicate scopes is invalid" do
      member = member!("guard-dup@fluxvale.com")

      changeset =
        PersonalAccessToken
        |> Ash.Changeset.new()
        |> Ash.Changeset.set_argument(:token_hash, PersonalAccessToken.token_hash("fvpat_y"))
        |> Ash.Changeset.for_create(:create, %{
          user_id: member.id,
          name: "x",
          expires_at: DateTime.add(DateTime.utc_now(), 60, :second),
          scopes: ["instances:read", "instances:read"]
        })

      assert {:error, %Ash.Error.Invalid{}} = Ash.create(changeset, authorize?: false)
    end
  end

  defp audit_rows(token_id) do
    FluxVale.Api.AuditEvent
    |> Ash.Query.for_read(:by_token, %{token_id: token_id})
    |> Ash.Query.sort([:created_at, :id])
    |> Ash.read!(authorize?: false)
  end
end
