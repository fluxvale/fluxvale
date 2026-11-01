defmodule FluxVale.RuntimeConfigTest do
  @moduledoc """
  The env-scoped gates in `config/runtime.exs` that keep a stray shell
  export from changing a suite/dev run's shape (#172): the
  `INSTANCES_SLUG_PREFIX` block and the `POSTMARK_API_KEY` mailer gate
  are both inert in the envs whose config files pin the answer
  (test.exs pins the Test adapter; config.exs pins Local for dev).

  The file is read through `Config.Reader` — the same evaluation the
  release uses — so the assertions are about the real file, not a
  paraphrase of it. Not async: env vars are VM-global.
  """

  use ExUnit.Case, async: false

  @runtime_config Path.expand("../../config/runtime.exs", __DIR__)

  # Prod's block insists on these; set so the prod reads below don't
  # raise. PLATFORM_ENV rides along (#196): a prod-shaped run without
  # it is exactly the misconfiguration the block refuses to boot on.
  @prod_env %{
    "DATABASE_URL" => "ecto://u:p@h/db",
    "SECRET_KEY_BASE" => "test-secret-key-base",
    "TOKEN_SIGNING_SECRET" => "test-token-signing-secret",
    "PLATFORM_ENV" => "production"
  }

  describe "INSTANCES_SLUG_PREFIX" do
    test "is inert in test — a stray export never prefixes minted slugs" do
      with_env(%{"INSTANCES_SLUG_PREFIX" => "stg"}, fn ->
        refute Keyword.has_key?(read!(:test)[:flux_vale] || [], :instances_slug_prefix)
      end)
    end

    test "is not validated in test — a bad value can't fail the suite at boot" do
      with_env(%{"INSTANCES_SLUG_PREFIX" => "Not A Prefix"}, fn ->
        assert read!(:test)
      end)
    end

    test "still applies (and validates) outside test" do
      with_env(%{"INSTANCES_SLUG_PREFIX" => "stg"}, fn ->
        assert read!(:dev)[:flux_vale][:instances_slug_prefix] == "stg"
      end)

      with_env(%{"INSTANCES_SLUG_PREFIX" => "Not A Prefix"}, fn ->
        assert_raise ArgumentError, ~r/INSTANCES_SLUG_PREFIX/, fn -> read!(:dev) end
      end)
    end
  end

  describe "ACCESS_DOMAIN_MONTHLY_CENTS (ADR-0040 §11)" do
    test "is inert in test — a stray export never reprices the suite's money paths" do
      with_env(%{"ACCESS_DOMAIN_MONTHLY_CENTS" => "500"}, fn ->
        # runtime.exs only ever OVERLAYS the key (config.exs owns the
        # default); inert in test means the overlay never lands.
        refute Keyword.has_key?(read!(:test)[:flux_vale] || [], :access_domain_pricing)
      end)
    end

    test "still applies (and validates) outside test" do
      with_env(%{"ACCESS_DOMAIN_MONTHLY_CENTS" => "500"}, fn ->
        assert read!(:dev)[:flux_vale][:access_domain_pricing][:monthly_cents] == 500
      end)

      with_env(%{"ACCESS_DOMAIN_MONTHLY_CENTS" => "free"}, fn ->
        assert_raise ArgumentError, ~r/ACCESS_DOMAIN_MONTHLY_CENTS/, fn -> read!(:dev) end
      end)

      with_env(%{"ACCESS_DOMAIN_MONTHLY_CENTS" => "0"}, fn ->
        assert_raise ArgumentError, ~r/ACCESS_DOMAIN_MONTHLY_CENTS/, fn -> read!(:dev) end
      end)
    end
  end

  describe "IDLE_SWEEP_CRONEXPR (#210 part 3)" do
    test "is inert in test — a stray export never compresses the suite's cadence" do
      with_env(%{"IDLE_SWEEP_CRONEXPR" => "* * * * *"}, fn ->
        oban = read!(:test)[:flux_vale][Oban] || []
        refute Keyword.has_key?(oban, :plugins)
      end)
    end

    test "reslots only the idle-sweep entry outside test" do
      with_env(%{"IDLE_SWEEP_CRONEXPR" => "* * * * *"}, fn ->
        oban = read!(:dev)[:flux_vale][Oban]
        plugins = Keyword.get(oban, :plugins, [])
        {_plugin, cron_opts} = List.keyfind(plugins, Oban.Plugins.Cron, 0)
        crontab = Keyword.get(cron_opts, :crontab, [])

        assert {"* * * * *", FluxVale.Workers.IdleInstanceSweep} in crontab
        # The other entries keep their config.exs homes — the override
        # reslots one line, it doesn't fork the crontab.
        assert {"0 3 * * *", FluxVale.Janitor.PruneExpiredTokens} in crontab
        assert {"7 * * * *", FluxVale.Workers.ZeroBalanceSweep} in crontab
        assert {"13 * * * *", FluxVale.Workers.StrandedInstanceSweep} in crontab
        assert {"6-59/5 * * * *", FluxVale.Workers.BackupSweep} in crontab
        assert {"1-59/15 * * * *", FluxVale.Janitor.VerifyAccessDomains} in crontab
        # ADR-0040 §11's domain-accrual tick (the S6 settler walk).
        assert {"3-59/15 * * * *", FluxVale.Workers.AccessDomainSettle} in crontab
        assert length(crontab) == 7
      end)
    end

    test "raises on a malformed expression — name the env var, not Oban's parser" do
      with_env(%{"IDLE_SWEEP_CRONEXPR" => "not a cron"}, fn ->
        assert_raise ArgumentError, ~r/IDLE_SWEEP_CRONEXPR/, fn -> read!(:dev) end
      end)
    end
  end

  describe "PLATFORM_ENV (#196)" do
    test "is required in :prod — unset refuses to boot rather than share one label" do
      with_env(Map.delete(@prod_env, "PLATFORM_ENV"), fn ->
        assert_raise ArgumentError, ~r/PLATFORM_ENV is required/, fn -> read!(:prod) end
      end)
    end

    test "a bad value raises in any env; unset leaves the config.exs default alone in dev" do
      # Unset first — with_env restores at test end, not between blocks,
      # so a lingering bad value would poison the unset read.
      with_env(%{}, fn ->
        refute Keyword.has_key?(read!(:dev)[:flux_vale] || [], :platform_env)
      end)

      with_env(%{"PLATFORM_ENV" => "not a label!"}, fn ->
        assert_raise ArgumentError, ~r/not a valid k8s label value/, fn -> read!(:dev) end
      end)

      # \z, not $: PCRE's $ matches before a trailing newline, and a
      # "staging\n" off a mounted Secret must fail at boot — not at the
      # k8s label rejection on the first deploy.
      with_env(%{"PLATFORM_ENV" => "staging\n"}, fn ->
        assert_raise ArgumentError, ~r/not a valid k8s label value/, fn -> read!(:dev) end
      end)
    end
  end

  describe "POSTMARK_API_KEY" do
    test "is inert in dev — a stray export keeps dev on the Local adapter" do
      with_env(%{"POSTMARK_API_KEY" => "stray-key"}, fn ->
        refute Keyword.has_key?(read!(:dev)[:flux_vale], FluxVale.Mailer)
      end)
    end

    test "is inert in test — the suite stays on Swoosh.Adapters.Test" do
      with_env(%{"POSTMARK_API_KEY" => "stray-key"}, fn ->
        refute Keyword.has_key?(read!(:test)[:flux_vale], FluxVale.Mailer)
      end)
    end

    test "flips delivery to Postmark in prod-shaped runs" do
      with_env(Map.put(@prod_env, "POSTMARK_API_KEY", "prod-key"), fn ->
        assert read!(:prod)[:flux_vale][FluxVale.Mailer] == [
                 adapter: Swoosh.Adapters.Postmark,
                 api_key: "prod-key"
               ]
      end)
    end
  end

  defp read!(env), do: Config.Reader.read!(@runtime_config, env: env)

  defp with_env(vars, fun) do
    originals = Map.new(vars, fn {name, _value} -> {name, System.get_env(name)} end)

    on_exit(fn -> Enum.each(originals, &restore_env/1) end)

    Enum.each(vars, fn {name, value} -> System.put_env(name, value) end)

    fun.()
  end

  defp restore_env({name, nil}), do: System.delete_env(name)
  defp restore_env({name, value}), do: System.put_env(name, value)
end
