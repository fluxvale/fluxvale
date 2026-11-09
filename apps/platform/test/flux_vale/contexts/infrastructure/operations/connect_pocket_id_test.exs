defmodule FluxVale.Infrastructure.Operations.ConnectPocketIdTest do
  @moduledoc """
  The wiring operation (#597 S4, §4.5): create → wire → deploy's
  middle leg. The happy path ships the SSO env (asserted as a map —
  the secret is never logged) and records the durable row; every
  failure is D3 fail-soft — an honest reason, the instance untouched,
  wiring recorded or absent. The PocketID API is Mimic-stubbed at the
  ApiClient seam (its own tests pin the wire contract); the held key
  rides S2's audited seam with real cluster stubs beneath it.
  """

  # Serialized (async: false): every test here enables the shared
  # feature-flag row, and cross-file lock-order cycles between that
  # row and seed_pricing!'s size rows deadlock under full-suite
  # concurrency (40P01, seen with the S2/S3 files running alongside).
  # One serialized stream keeps the suite deterministic.
  use FluxVale.DataCase, async: false
  use Mimic

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Infrastructure
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.PocketId.ApiClient
  alias FluxVale.Infrastructure.PocketIdCustody
  alias FluxVale.Infrastructure.PocketIdCustodyEvent
  alias FluxVale.Infrastructure.PocketIdWiring
  alias FluxVale.Ops.FeatureFlags
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  @held_key "held-key-not-a-real-credential"
  @minted_secret "minted-secret-never-logged"
  @issuer "https://id.example"
  @callback_path "/identity/connect/oidc-signin"

  @sso_specs %{
    "SSO_AUTHORITY" => %{label: "OIDC issuer URL", type: :string},
    "SSO_CLIENT_ID" => %{label: "OIDC client ID", type: :string},
    "SSO_CLIENT_SECRET" => %{label: "OIDC client secret", type: :string, secret: true},
    "SSO_ENABLED" => %{label: "Enable Pocket ID sign-in", type: :boolean, default: false}
  }

  @schema Map.put(@sso_specs, "SMTP_HOST", %{label: "SMTP host", type: :string})

  @recipe %{
    "kind" => "env",
    "issuer_env" => "SSO_AUTHORITY",
    "client_id_env" => "SSO_CLIENT_ID",
    "client_secret_env" => "SSO_CLIENT_SECRET",
    "enabled_env" => "SSO_ENABLED",
    "pkce" => true
  }

  setup do
    # The fail-closed gate is part of what's under test: enable
    # through the real verb, never by minting a row.
    :ok = FeatureFlags.enable(:pocketid_sso_wiring, actor: AccountsFixtures.platform_admin!())

    InstanceFixtures.local_cluster!()
    {org, owner} = BillingFixtures.grant_free_org!()
    # Instance create rides the funded-wallet gate (#124).
    BillingFixtures.funded_wallet!(org: org)

    stub(K8s, :kubeconfig, fn _ref -> {:ok, %{}} end)

    pocket_id_version =
      InstanceFixtures.app_version!(app_slug: "pocket-id", configurable_env_vars: %{})

    # The active, public, custody-ready PocketID (§4.1's shape).
    pocket_id =
      pocket_id_version
      |> InstanceFixtures.instance!(owner)
      |> InstanceFixtures.walk_to!(:running)
      |> InstanceFixtures.pin!(namespace: "ns")

    PocketIdCustody.record!(
      %{
        organization_id: pocket_id.organization_id,
        instance_id: pocket_id.id,
        api_key_secret_ref: "fluxvale-pocketid-custody-#{pocket_id.id}",
        verified_at: DateTime.utc_now()
      },
      authorize?: false
    )

    stub(Secret, :get_data, fn _kc, _ns, _ref ->
      {:ok, %{"POCKETID_API_KEY" => @held_key}}
    end)

    {:ok, org: org, owner: owner, pocket_id: pocket_id}
  end

  # The SSO-carrying app instance, `env` riding the create's argument
  # (the #482 wire path — pre-existing values are exactly the shape a
  # crafted ride-along would produce). `recipe_overrides` for the
  # optional pieces (an enabled_env-less recipe) — stringified before
  # the merge so a keyword override actually lands: @recipe carries
  # string keys, and Map.new(enabled_env: nil) would add a parallel
  # atom key the merge never touches.
  defp sso_instance!(
         owner,
         version_attrs \\ [],
         env \\ %{},
         recipe_overrides \\ %{},
         instance_attrs \\ %{}
       ) do
    overrides = Map.new(recipe_overrides, fn {key, value} -> {to_string(key), value} end)
    recipe = Map.merge(@recipe, overrides)

    version =
      InstanceFixtures.app_version!(
        [
          configurable_env_vars: @schema,
          oidc_wiring: recipe,
          oidc_callback_path: @callback_path
        ] ++ version_attrs
      )

    params = %{name: "Inst #{System.unique_integer()}", app_version_id: version.id, env_vars: env}
    merged_params = Map.merge(params, Map.new(instance_attrs))

    Instance.create!(merged_params, actor: owner)
  end

  # The full green stub set: discovery answers the issuer, the mint
  # yields PocketID's ids and the one-time secret — pinned against
  # the app instance's own derivations (name, callback URL).
  defp green_stubs!(pocket_id, app) do
    url = pocket_id_url(pocket_id)
    name = "FluxVale · #{app.name}"
    callback = "https://#{app.slug}.#{host()}#{@callback_path}"

    stub(ApiClient, :get_discovery, fn ^url -> {:ok, @issuer} end)

    stub(ApiClient, :create_client, fn ^url, @held_key, attrs ->
      assert attrs.name == name
      assert attrs.callback_url == callback
      assert attrs.pkce

      {:ok, %{client_id: "pid-1", client_name: name, secret_id: "sec-1", secret: @minted_secret}}
    end)
  end

  # PocketID's DTO cap counts RUNES (codepoints); a grapheme-heavy
  # name must still come in under it (CodeRabbit's combining-accent
  # case — grapheme slicing would exceed the cap). Pinned through the
  # public seam: the mint's attrs.
  test "a grapheme-heavy instance name stays under PocketID's codepoint cap", %{
    owner: owner,
    pocket_id: pocket_id
  } do
    # 45 graphemes of TWO codepoints each (e + combining acute) —
    # grapheme slicing at 39 keeps all 45; codepoint slicing cannot.
    decomposed = String.duplicate("e\u0301", 45)
    app = sso_instance!(owner, [], %{}, %{}, name: decomposed)
    url = pocket_id_url(pocket_id)

    stub(ApiClient, :get_discovery, fn ^url -> {:ok, @issuer} end)

    stub(ApiClient, :create_client, fn ^url, @held_key, attrs ->
      assert length(String.codepoints(attrs.name)) <= 50

      {:ok,
       %{client_id: "pid-1", client_name: attrs.name, secret_id: "sec-1", secret: @minted_secret}}
    end)

    assert {:ok, _wiring} = Infrastructure.connect_pocket_id(app, pocket_id.id, actor: owner)
  end

  defp host, do: Application.fetch_env!(:flux_vale, :instances_base_domain)

  defp pocket_id_url(pocket_id), do: "https://#{pocket_id.slug}.#{host()}"

  defp reloaded!(instance), do: Instance.get_by_id!(instance.id, authorize?: false)

  defp wiring_events(pocket_id) do
    {:ok, rows} = PocketIdCustodyEvent.for_instance(pocket_id.id, authorize?: false)
    rows
  end

  describe "the happy path — env shipped, row recorded, mint audited" do
    test "ships the recipe's env verbatim and records PocketID's ids", %{
      owner: owner,
      pocket_id: pocket_id
    } do
      app = sso_instance!(owner)
      green_stubs!(pocket_id, app)

      assert {:ok, wiring} = Infrastructure.connect_pocket_id(app, pocket_id.id, actor: owner)

      # The durable record: PocketID's own ids, never the secret.
      assert wiring.instance_id == app.id
      assert wiring.pocket_id_instance_id == pocket_id.id
      assert wiring.pocket_id_client_id == "pid-1"
      assert wiring.pocket_id_secret_id == "sec-1"
      assert %DateTime{} = wiring.wired_at
      refute "#{inspect(wiring)}" =~ @minted_secret

      # The env the next deploy ships: the recipe's keys, strings end
      # to end, the issuer VERBATIM — asserted as a map, never logged.
      env = reloaded!(app).env_vars
      assert env["SSO_AUTHORITY"] == @issuer
      assert env["SSO_CLIENT_ID"] == "pid-1"
      assert env["SSO_CLIENT_SECRET"] == @minted_secret
      assert env["SSO_ENABLED"] == "true"

      # The mint rode the audited seam: a :used event, purpose named.
      assert [%PocketIdCustodyEvent{kind: :used, purpose: "client_mint"}] =
               wiring_events(pocket_id)
    end

    test "a recipe without enabled_env wires without the toggle — every named key ships", %{
      owner: owner,
      pocket_id: pocket_id
    } do
      # enabled_env is the recipe's one optional name (S1's shape): a
      # version that omits it wires everything it names and nothing
      # more — no stray SSO_ENABLED lands in env.
      app = sso_instance!(owner, [], %{}, enabled_env: nil)
      green_stubs!(pocket_id, app)

      assert {:ok, _wiring} = Infrastructure.connect_pocket_id(app, pocket_id.id, actor: owner)

      env = reloaded!(app).env_vars
      assert env["SSO_AUTHORITY"] == @issuer
      assert env["SSO_CLIENT_ID"] == "pid-1"
      assert env["SSO_CLIENT_SECRET"] == @minted_secret
      # The toggle the recipe never names is the create-time schema
      # default, untouched by the wiring (it force-changes only the
      # recipe's keys).
      assert env["SSO_ENABLED"] == "false"
    end

    test "user env is untouched — a crafted ride-along under a recipe key cannot win", %{
      owner: owner,
      pocket_id: pocket_id
    } do
      # A pre-existing user value (unrelated key) plus a hostile value
      # under a recipe key: the wiring force-owns the recipe's keys;
      # everything else survives verbatim.
      app =
        sso_instance!(owner, [], %{
          "SMTP_HOST" => "smtp.example",
          "SSO_AUTHORITY" => "https://hostile.example"
        })

      green_stubs!(pocket_id, app)

      assert {:ok, _wiring} = Infrastructure.connect_pocket_id(app, pocket_id.id, actor: owner)

      env = reloaded!(app).env_vars
      assert env["SMTP_HOST"] == "smtp.example"
      assert env["SSO_AUTHORITY"] == @issuer
    end

    test "a re-wire replaces the row — one active wiring, ids follow the new client", %{
      owner: owner,
      pocket_id: pocket_id
    } do
      app = sso_instance!(owner)
      green_stubs!(pocket_id, app)

      assert {:ok, first} = Infrastructure.connect_pocket_id(app, pocket_id.id, actor: owner)

      url = pocket_id_url(pocket_id)

      stub(ApiClient, :create_client, fn ^url, @held_key, attrs ->
        {:ok,
         %{
           client_id: "pid-2",
           client_name: attrs.name,
           secret_id: "sec-2",
           secret: "second-secret-never-logged"
         }}
      end)

      assert {:ok, second} = Infrastructure.connect_pocket_id(app, pocket_id.id, actor: owner)

      assert second.id != first.id
      assert second.pocket_id_client_id == "pid-2"
      assert {:ok, found} = PocketIdWiring.get_by_instance(app.id, authorize?: false)
      assert found.id == second.id
      assert reloaded!(app).env_vars["SSO_CLIENT_SECRET"] == "second-secret-never-logged"
    end
  end

  # Terence's explicit ask: the sleeping-PocketID path pinned — the
  # discovery/create call fails, wiring answers fail-soft, the
  # instance stays deployable, and a retry converges once the host
  # answers.
  # #597 S5 (§4.6): the retrofit — the same pipeline for a DEPLOYED
  # instance, plus the apply primitive carrying the env to the
  # RUNNING workload. Row first (truth), then apply (converges).
  describe "retrofit/3 (the deployed-instance wiring)" do
    test "wires a running instance: row + wiring, then the live workload carries the env", %{
      owner: owner,
      pocket_id: pocket_id
    } do
      app =
        owner
        |> sso_instance!()
        |> InstanceFixtures.walk_to!(:running)
        |> InstanceFixtures.pin!(namespace: "ns-retro")

      green_stubs!(pocket_id, app)

      expect(Secret, :upsert, fn _kc, "ns-retro", "app-env", data ->
        send(self(), {:applied, data})
        {:ok, %{}}
      end)

      expect(Deployment, :restart, fn _kc, "ns-retro", "app" -> {:ok, %{}} end)

      assert {:ok, wiring} =
               Infrastructure.retrofit_pocket_id(app, pocket_id.id, actor: owner)

      assert wiring.pocket_id_client_id == "pid-1"

      # The row carries the wiring's values (the next re-deploy shape)…
      reloaded = reloaded!(app)
      assert reloaded.env_vars["SSO_AUTHORITY"] == @issuer
      assert reloaded.env_vars["SSO_CLIENT_SECRET"] == @minted_secret

      # …and the RUNNING workload got them through the primitive.
      assert_received {:applied, applied}
      assert applied["SSO_AUTHORITY"] == @issuer
      assert applied["SSO_CLIENT_SECRET"] == @minted_secret
      assert applied["SSO_ENABLED"] == "true"
    end

    test "a pre-deploy instance refuses — that's call/3's lane", %{
      owner: owner,
      pocket_id: pocket_id
    } do
      app = sso_instance!(owner)
      green_stubs!(pocket_id, app)

      assert {:error, {:instance_not_deployed, :pending}} =
               Infrastructure.retrofit_pocket_id(app, pocket_id.id, actor: owner)

      assert {:error, _none} = PocketIdWiring.get_by_instance(app.id, authorize?: false)
    end

    test "a failed apply keeps the recorded wiring — the retry converges (row is truth)", %{
      owner: owner,
      pocket_id: pocket_id
    } do
      app =
        owner
        |> sso_instance!()
        |> InstanceFixtures.walk_to!(:running)
        |> InstanceFixtures.pin!(namespace: "ns-retro2")

      green_stubs!(pocket_id, app)

      stub(Secret, :upsert, fn _kc, _ns, _n, _d ->
        {:error, %K8s.Error{status_code: 500, reason: :unknown, message: "no"}}
      end)

      assert {:error, %K8s.Error{}} =
               Infrastructure.retrofit_pocket_id(app, pocket_id.id, actor: owner)

      # Recorded (the card retries the apply), env on the row, no half-state.
      assert {:ok, _wiring} = PocketIdWiring.get_by_instance(app.id, authorize?: false)
      assert reloaded!(app).env_vars["SSO_AUTHORITY"] == @issuer
    end
  end

  describe "the wake race (D3 — never blocks the deploy)" do
    test "a 503 discovery fails soft: honest reason, instance untouched, no row", %{
      owner: owner,
      pocket_id: pocket_id
    } do
      app = sso_instance!(owner)
      url = pocket_id_url(pocket_id)

      stub(ApiClient, :get_discovery, fn ^url -> {:error, %{status: 503, body: "waking"}} end)
      stub(ApiClient, :create_client, fn ^url, _key, _attrs -> flunk("no mint mid-wake") end)

      assert {:error, :unreachable} =
               Infrastructure.connect_pocket_id(app, pocket_id.id, actor: owner)

      # Fully deployable: still pending, env as created, wiring absent.
      instance = reloaded!(app)
      assert instance.status == :pending
      assert instance.env_vars == app.env_vars
      assert {:error, _none} = PocketIdWiring.get_by_instance(app.id, authorize?: false)
      # No key use happened: nothing to audit.
      assert [] = wiring_events(pocket_id)
    end

    test "a transport-level discovery failure is the same fail-soft answer", %{
      owner: owner,
      pocket_id: pocket_id
    } do
      app = sso_instance!(owner)
      url = pocket_id_url(pocket_id)

      stub(ApiClient, :get_discovery, fn ^url -> {:error, :unreachable} end)

      assert {:error, :unreachable} =
               Infrastructure.connect_pocket_id(app, pocket_id.id, actor: owner)
    end

    # The locked re-read's race (CodeRabbit): a deploy landing in the
    # seconds the network legs take must not let the wiring row commit
    # over a live instance whose env Secret shipped without SSO — the
    # transaction's FOR UPDATE re-guard refuses honestly.
    test "a deploy racing the window refuses at the locked re-read, never half-wires", %{
      owner: owner,
      pocket_id: pocket_id
    } do
      app = sso_instance!(owner)
      url = pocket_id_url(pocket_id)

      # The window: discovery answers its issuer while — behind the
      # wizard's back — the instance deploys mid-call.
      stub(ApiClient, :get_discovery, fn ^url ->
        racing = reloaded!(app)
        InstanceFixtures.walk_to!(racing, :running)
        {:ok, @issuer}
      end)

      stub(ApiClient, :create_client, fn ^url, _key, _attrs ->
        {:ok, %{client_id: "pid-1", client_name: "n", secret_id: "sec-1", secret: @minted_secret}}
      end)

      assert {:error, {:instance_running, :running}} =
               Infrastructure.connect_pocket_id(app, pocket_id.id, actor: owner)

      moved = reloaded!(app)
      assert moved.status == :running
      refute Map.has_key?(moved.env_vars, "SSO_AUTHORITY")
      assert {:error, _none} = PocketIdWiring.get_by_instance(app.id, authorize?: false)
    end

    test "the mint leg fails soft too (create unreachable after discovery)", %{
      owner: owner,
      pocket_id: pocket_id
    } do
      app = sso_instance!(owner)
      url = pocket_id_url(pocket_id)

      stub(ApiClient, :get_discovery, fn ^url -> {:ok, @issuer} end)
      stub(ApiClient, :create_client, fn ^url, _key, _attrs -> {:error, :unreachable} end)

      assert {:error, :unreachable} =
               Infrastructure.connect_pocket_id(app, pocket_id.id, actor: owner)

      # The key WAS read for the mint attempt (audited use); the
      # wiring itself is absent.
      assert [%PocketIdCustodyEvent{kind: :used, purpose: "client_mint"}] =
               wiring_events(pocket_id)

      assert {:error, _none} = PocketIdWiring.get_by_instance(app.id, authorize?: false)
    end

    test "retry succeeds once the host answers — the row lands, env ships", %{
      owner: owner,
      pocket_id: pocket_id
    } do
      app = sso_instance!(owner)
      url = pocket_id_url(pocket_id)

      stub(ApiClient, :get_discovery, fn ^url -> {:error, :unreachable} end)

      assert {:error, :unreachable} =
               Infrastructure.connect_pocket_id(app, pocket_id.id, actor: owner)

      # PocketID woke: the same call now wires.
      green_stubs!(pocket_id, app)

      assert {:ok, wiring} = Infrastructure.connect_pocket_id(app, pocket_id.id, actor: owner)
      assert wiring.pocket_id_client_id == "pid-1"
      assert reloaded!(app).env_vars["SSO_AUTHORITY"] == @issuer
    end
  end

  describe "key verdicts at the mint (401/403 never folded)" do
    test "a rejected key (401) is :key_rejected — wiring absent", %{
      owner: owner,
      pocket_id: pocket_id
    } do
      app = sso_instance!(owner)
      url = pocket_id_url(pocket_id)

      stub(ApiClient, :get_discovery, fn ^url -> {:ok, @issuer} end)
      stub(ApiClient, :create_client, fn ^url, _key, _attrs -> {:error, :unauthorized} end)

      assert {:error, :key_rejected} =
               Infrastructure.connect_pocket_id(app, pocket_id.id, actor: owner)

      assert {:error, _none} = PocketIdWiring.get_by_instance(app.id, authorize?: false)
    end

    test "a key without client rights (403) is :key_forbidden", %{
      owner: owner,
      pocket_id: pocket_id
    } do
      app = sso_instance!(owner)
      url = pocket_id_url(pocket_id)

      stub(ApiClient, :get_discovery, fn ^url -> {:ok, @issuer} end)
      stub(ApiClient, :create_client, fn ^url, _key, _attrs -> {:error, :forbidden} end)

      assert {:error, :key_forbidden} =
               Infrastructure.connect_pocket_id(app, pocket_id.id, actor: owner)
    end
  end

  describe "the guards — every refusal happens before the mint" do
    test "no recipe on the version is :recipe_missing", %{owner: owner, pocket_id: pocket_id} do
      app = sso_instance!(owner, oidc_wiring: nil)
      url = pocket_id_url(pocket_id)

      stub(ApiClient, :get_discovery, fn ^url -> flunk("no calls without a recipe") end)

      assert {:error, :recipe_missing} =
               Infrastructure.connect_pocket_id(app, pocket_id.id, actor: owner)
    end

    test "an :in_app recipe is honestly not-wired-yet", %{owner: owner, pocket_id: pocket_id} do
      app = sso_instance!(owner, oidc_wiring: Map.put(@recipe, "kind", "in_app"))
      url = pocket_id_url(pocket_id)

      stub(ApiClient, :get_discovery, fn ^url -> flunk("no calls for an in-app recipe") end)

      assert {:error, :recipe_not_env} =
               Infrastructure.connect_pocket_id(app, pocket_id.id, actor: owner)
    end

    test "a recipe whose version declares no callback path cannot name the redirect", %{
      owner: owner,
      pocket_id: pocket_id
    } do
      app = sso_instance!(owner, oidc_callback_path: nil)
      url = pocket_id_url(pocket_id)

      stub(ApiClient, :get_discovery, fn ^url -> flunk("no discovery without a callback") end)

      assert {:error, :no_callback_path} =
               Infrastructure.connect_pocket_id(app, pocket_id.id, actor: owner)
    end

    test "an unknown PocketID id is :pocket_id_not_found (the crafted shape)", %{
      owner: owner
    } do
      app = sso_instance!(owner)

      stub(ApiClient, :get_discovery, fn _url -> flunk("no calls for an unknown PocketID") end)

      assert {:error, :pocket_id_not_found} =
               Infrastructure.connect_pocket_id(app, Ash.UUID.generate(), actor: owner)
    end

    test "a PocketID from another org is the Forbidden-shaped answer", %{owner: owner} do
      app = sso_instance!(owner)

      # The op takes the PocketID instance directly (no slug detection
      # — that's S3's read), so a unique fabricated slug is fine and
      # avoids colliding with setup's PocketID app.
      pocket_id_version =
        InstanceFixtures.app_version!(
          app_slug: "pocket-id-#{System.unique_integer()}",
          configurable_env_vars: %{}
        )

      {other_org, stranger} = BillingFixtures.grant_free_org!()
      BillingFixtures.funded_wallet!(org: other_org)

      foreign_pocket_id =
        pocket_id_version
        |> InstanceFixtures.instance!(stranger)
        |> InstanceFixtures.walk_to!(:running)
        |> InstanceFixtures.pin!(namespace: "ns")

      stub(ApiClient, :get_discovery, fn _url -> flunk("no calls across the org fence") end)

      assert {:error, :forbidden} =
               Infrastructure.connect_pocket_id(app, foreign_pocket_id.id, actor: owner)
    end

    test "a private PocketID is refused before any HTTP", %{owner: owner, pocket_id: pocket_id} do
      app = sso_instance!(owner)
      private = InstanceFixtures.pin!(pocket_id, exposure: :private)

      stub(ApiClient, :get_discovery, fn _url -> flunk("no calls for a private PocketID") end)

      assert {:error, :not_public} =
               Infrastructure.connect_pocket_id(app, private.id, actor: owner)
    end

    test "no custody is :no_custody", %{owner: owner, pocket_id: pocket_id} do
      app = sso_instance!(owner)
      custody = PocketIdCustody.get_by_instance!(pocket_id.id, authorize?: false)
      :ok = PocketIdCustody.revoke(custody, authorize?: false)

      stub(ApiClient, :get_discovery, fn _url -> flunk("no calls without custody") end)

      assert {:error, :no_custody} =
               Infrastructure.connect_pocket_id(app, pocket_id.id, actor: owner)
    end

    test "a deployed instance refuses with the S5 posture", %{
      owner: owner,
      pocket_id: pocket_id
    } do
      app =
        owner
        |> sso_instance!()
        |> InstanceFixtures.walk_to!(:running)

      green_stubs!(pocket_id, app)

      assert {:error, {:instance_running, :running}} =
               Infrastructure.connect_pocket_id(app, pocket_id.id, actor: owner)

      assert {:error, _none} = PocketIdWiring.get_by_instance(app.id, authorize?: false)
    end

    # Not the running tuple's words — a deleting instance has nothing
    # to wire and nothing landing with any future card.
    test "a deleting instance refuses as its own honest atom", %{
      owner: owner,
      pocket_id: pocket_id
    } do
      app = sso_instance!(owner)

      app
      |> Ash.Changeset.for_update(:update_status, %{status: :deleting}, authorize?: false)
      |> Ash.update!()

      green_stubs!(pocket_id, app)

      assert {:error, :instance_deleting} =
               Infrastructure.connect_pocket_id(app, pocket_id.id, actor: owner)

      assert {:error, _none} = PocketIdWiring.get_by_instance(app.id, authorize?: false)
    end

    test "a non-member actor cannot read the target — NotFound (the membership filter's stance)",
         %{
           owner: owner,
           pocket_id: pocket_id
         } do
      app = sso_instance!(owner)
      {_other_org, stranger} = BillingFixtures.grant_free_org!()

      stub(ApiClient, :get_discovery, fn _url -> flunk("no calls for a stranger") end)

      # The authorized get? read filters strangers to not-found (the
      # custody read's own posture) — indistinguishable from an
      # unknown id, which is the point.
      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
               Infrastructure.connect_pocket_id(app, pocket_id.id, actor: stranger)
    end

    test "the flag off means :flag_disabled — fail-closed before anything", %{
      owner: owner,
      pocket_id: pocket_id
    } do
      :ok = FeatureFlags.disable(:pocketid_sso_wiring, actor: AccountsFixtures.platform_admin!())
      app = sso_instance!(owner)

      stub(ApiClient, :get_discovery, fn _url -> flunk("no calls while the flag is off") end)

      assert {:error, :flag_disabled} =
               Infrastructure.connect_pocket_id(app, pocket_id.id, actor: owner)
    end
  end
end
