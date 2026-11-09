defmodule FluxVale.Clients.K8s.Resources.StorageClassTest do
  use ExUnit.Case, async: true
  use Mimic

  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.StorageClass

  setup do
    stub(Kubereq, :attach, fn req, _opts -> req end)
    :ok
  end

  defp class(name, opts \\ []) do
    %{
      "metadata" => %{
        "name" => name,
        "annotations" =>
          if(Keyword.get(opts, :default, false),
            do: %{"storageclass.kubernetes.io/is-default-class" => "true"},
            else: %{}
          )
      },
      # The real storage.k8s.io/v1 shape: top-level, no `spec`.
      "allowVolumeExpansion" => Keyword.get(opts, :expandable, false)
    }
  end

  describe "default_allows_expansion?/1" do
    test "the default class expanding is capable" do
      expect(Kubereq, :list, fn _req ->
        {:ok,
         %{
           status: 200,
           body: %{
             "items" => [class("local-path"), class("topolvm", default: true, expandable: true)]
           }
         }}
      end)

      assert {:ok, true} = StorageClass.default_allows_expansion?(%{})
    end

    test "a default class without expansion is not capable (local-path today)" do
      expect(Kubereq, :list, fn _req ->
        {:ok, %{status: 200, body: %{"items" => [class("local-path", default: true)]}}}
      end)

      assert {:ok, false} = StorageClass.default_allows_expansion?(%{})
    end

    test "no default class is not capable — even with an expandable non-default one" do
      expect(Kubereq, :list, fn _req ->
        {:ok, %{status: 200, body: %{"items" => [class("topolvm", expandable: true)]}}}
      end)

      assert {:ok, false} = StorageClass.default_allows_expansion?(%{})
    end

    test "among multiple defaults, an expanding one counts" do
      expect(Kubereq, :list, fn _req ->
        {:ok,
         %{
           status: 200,
           body: %{
             "items" => [
               class("a", default: true),
               class("b", default: true, expandable: true)
             ]
           }
         }}
      end)

      assert {:ok, true} = StorageClass.default_allows_expansion?(%{})
    end

    test "malformed 200 body is a validation error, not a from_response crash" do
      expect(Kubereq, :list, fn _req -> {:ok, %{status: 200, body: %{"unexpected" => 1}}} end)

      assert {:error, %Error{reason: :validation_error}} =
               StorageClass.default_allows_expansion?(%{})
    end

    test "error statuses map through from_response" do
      expect(Kubereq, :list, fn _req -> {:ok, %{status: 403, body: %{}}} end)

      assert {:error, %Error{}} = StorageClass.default_allows_expansion?(%{})
    end

    test "transport failure maps to a connection error" do
      expect(Kubereq, :list, fn _req -> {:error, :transport_oops} end)

      assert {:error, %Error{reason: :connection_error}} =
               StorageClass.default_allows_expansion?(%{})
    end
  end
end
