defmodule FluxVale.RequiredEnvsTest do
  @moduledoc """
  `apps/platform/required-envs.txt` is the boot-guard contract the
  fleet overlays must carry (#242): every listed env is one the
  prod-mode release raises without, so a fleet overlay missing one
  crash-loops the rollout while PR CI stays green (the Oct-23
  PLATFORM_ENV incident class).

  This suite pins the list in both directions so it can't rot:

  - **no orphans**: dropping any listed env from a prod-shaped boot
    raises naming it — the fleet assert stays honest, not a wishlist;
  - **no gaps**: a prod read with ONLY the listed envs (plus their
    values here) succeeds — the next boot-guard env added to
    `config/runtime.exs` without a line in the file fails this test
    by raising with its name in the message.
  """

  use ExUnit.Case, async: false

  @runtime_config Path.expand("../../config/runtime.exs", __DIR__)
  @required_envs Path.expand("../../required-envs.txt", __DIR__)

  # Known-valid values for the prod read — the same shape the fleet
  # overlays carry (discrete DB_* vars; DATABASE_URL unset — the URL
  # compose in runtime.exs builds it from these).
  @valid_values %{
    "PLATFORM_ENV" => "staging",
    "DB_HOST" => "fluxvale-cnpg-pooler.fluxvale-db.svc.cluster.local",
    "DB_USER" => "flux",
    "SECRET_KEY_BASE" => "test-secret-key-base",
    "TOKEN_SIGNING_SECRET" => "test-token-signing-secret"
  }

  # The prod raise names DATABASE_URL when DB_HOST is the missing
  # piece (the compose raises before anything mentions DB_HOST) — the
  # alias keeps the orphan test asserting on the actual message.
  @raise_names %{"DB_HOST" => "DATABASE_URL"}

  # Env vars whose ambient values could satisfy the prod read without
  # appearing in the file (the URL compose family) — cleared so the
  # minimal-env test is about the file's contents, not this shell.
  @ambient_shape [
    "DATABASE_URL",
    "DB_HOST",
    "DB_NAME",
    "DB_PASSWORD",
    "DB_PORT",
    "DB_USER"
  ]

  test "the file and its known values agree — every name has a fixture" do
    for name <- required_envs() do
      assert Map.has_key?(@valid_values, name), "#{name} has no fixture value in @valid_values"
    end
  end

  test "no orphans: dropping any listed env raises at a prod-shaped boot" do
    for dropped <- required_envs() do
      env = Map.delete(@valid_values, dropped)

      error = with_clean_shell(fn -> boot_error(env) end)

      expected = Map.get(@raise_names, dropped, dropped)

      assert error != nil, "expected a prod boot without #{dropped} to raise"
      assert Exception.message(error) =~ expected
    end
  end

  test "no gaps: a prod read with only the listed envs succeeds" do
    config = with_clean_shell(fn -> read_prod!(@valid_values) end)

    endpoint = config[:flux_vale][FluxValeWeb.Endpoint] || []
    assert endpoint[:secret_key_base] == "test-secret-key-base"
    assert config[:flux_vale][:platform_env] == "staging"
  end

  # The demo-seed gate's computation, pinned both arms (#412): the
  # discriminator is the PLATFORM_ENV VAR, not the application env —
  # config writes in runtime.exs buffer until the file finishes
  # evaluating, so an Application.get_env read beside this block would
  # see the config.exs-baked value and never tell production from
  # staging (the stale-read lesson; the retired DEMO_SEEDS gate shared
  # it). These two arms are the whole rule: non-production platforms
  # seed the demo board, production boots stay honestly empty no matter
  # what else the shell carries.
  test "demo board content seeds on a non-production platform env" do
    config = with_clean_shell(fn -> read_prod!(@valid_values) end)

    assert config[:flux_vale][:seed_demo_content] == true
  end

  test "a production platform env boots with the demo board empty" do
    production = Map.put(@valid_values, "PLATFORM_ENV", "production")

    config = with_clean_shell(fn -> read_prod!(production) end)

    assert config[:flux_vale][:platform_env] == "production"
    refute config[:flux_vale][:seed_demo_content]
  end

  # A TYPO of production must not seed either: "prod" passes the
  # k8s-label validation, so the gate allowlists the known non-prod
  # values instead of excluding the one spelled correctly (the
  # review finding this shape).
  test "a typo of the production platform env stays empty too" do
    typo = Map.put(@valid_values, "PLATFORM_ENV", "prod")

    config = with_clean_shell(fn -> read_prod!(typo) end)

    refute config[:flux_vale][:seed_demo_content]
  end

  defp required_envs do
    @required_envs
    |> File.read!()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&line_is_ignorable?/1)
  end

  defp line_is_ignorable?(line), do: line == "" or String.starts_with?(line, "#")

  defp read_prod!(vars) do
    # Tests own their preconditions: capture-and-restore every variable
    # this helper touches, including on failure — a blind delete would
    # strip values the surrounding shell already carried and later tests
    # would observe them missing (the CodeRabbit catch). The snapshot
    # binds BEFORE the try: an after block cannot see body bindings.
    keys = Map.keys(vars)
    prior = Map.new(keys, &{&1, System.get_env(&1)})

    try do
      env = Map.new(vars)
      System.put_env(env)

      Config.Reader.read!(@runtime_config, env: :prod)
    after
      Enum.each(prior, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end

  # Both directions run against a shell scrubbed of the URL-compose
  # family — an exported DATABASE_URL in a dev shell would otherwise
  # satisfy the DB_HOST drop (orphan test false-red) and mask a
  # missing DB_HOST (gap test false-green).
  defp with_clean_shell(fun) do
    in_shell = Map.new(@ambient_shape, fn name -> {name, System.get_env(name)} end)
    Enum.each(@ambient_shape, &System.delete_env/1)

    try do
      fun.()
    after
      Enum.each(in_shell, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end

  defp boot_error(env) do
    read_prod!(env)
    nil
  rescue
    error -> error
  end
end
