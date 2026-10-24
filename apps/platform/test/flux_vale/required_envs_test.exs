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

  defp required_envs do
    @required_envs
    |> File.read!()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&line_is_ignorable?/1)
  end

  defp line_is_ignorable?(line), do: line == "" or String.starts_with?(line, "#")

  defp read_prod!(vars) do
    env = Map.new(vars)
    System.put_env(env)

    Config.Reader.read!(@runtime_config, env: :prod)
  after
    keys = Map.keys(vars)
    Enum.each(keys, &System.delete_env/1)
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
