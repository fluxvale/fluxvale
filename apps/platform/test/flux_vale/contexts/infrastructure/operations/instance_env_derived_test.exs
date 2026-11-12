defmodule FluxVale.Infrastructure.Operations.InstanceEnvDerivedTest do
  @moduledoc false

  # #731: the shared allowlist append — one owner for the deploy and the
  # in-place patch. Idempotent: a value already carrying the platform
  # host keeps the user's string exactly.

  use ExUnit.Case, async: true

  alias FluxVale.Infrastructure.Operations.InstanceEnvDerived

  defp host(slug) do
    "#{slug}.#{Application.fetch_env!(:flux_vale, :instances_base_domain)}"
  end

  defp instance(slug \\ "app"), do: %{exposure: :public, slug: slug}
  defp version, do: %{host_allowlist_env: "ALLOWED_HOSTS"}

  test "nil becomes the platform host" do
    assert InstanceEnvDerived.allowlist_entry(%{}, instance(), version()) == %{
             "ALLOWED_HOSTS" => host("app")
           }
  end

  test "multiple hosts get the platform host appended once" do
    assert InstanceEnvDerived.allowlist_entry(
             %{"ALLOWED_HOSTS" => "localhost,127.0.0.1"},
             instance(),
             version()
           ) == %{"ALLOWED_HOSTS" => "localhost,127.0.0.1,#{host("app")}"}
  end

  test "a value already containing the platform host is preserved exactly" do
    existing = "localhost, #{host("app")}"

    assert InstanceEnvDerived.allowlist_entry(
             %{"ALLOWED_HOSTS" => existing},
             instance(),
             version()
           ) == %{"ALLOWED_HOSTS" => existing}
  end

  test "a nil host_allowlist_env leaves the map untouched" do
    env = %{"KEEP" => "1"}

    assert InstanceEnvDerived.allowlist_entry(env, instance(), %{host_allowlist_env: nil}) ==
             env
  end
end
