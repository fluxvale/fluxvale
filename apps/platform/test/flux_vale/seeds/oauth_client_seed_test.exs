defmodule FluxVale.Seeds.OAuthClientSeedTest do
  @moduledoc """
  The first-party OAuth client seed (#886) against a sandboxed DB —
  create-if-missing only: the first run registers the CLI's device-
  grant client, a re-seed writes nothing.
  """

  # Sync: a seed writes shared rows, so it must not overlap another test.

  use FluxVale.DataCase, async: false

  alias FluxVale.OAuth.Client
  alias FluxVale.Seeds

  describe "seed_oauth_client!/0" do
    test "the first run registers the CLI client with no redirect URIs" do
      assert :ok == Seeds.seed_oauth_client!()

      client_id = Application.get_env(:flux_vale, :oauth_device_client_id)
      assert {:ok, client} = Client.get_by_client_id(client_id, authorize?: false)
      assert client.client_name == "FluxVale CLI"
      assert client.redirect_uris == []
      assert client.token_endpoint_auth_method == "none"
    end

    test "a re-seed is a no-op — the row keeps its identity" do
      assert :ok == Seeds.seed_oauth_client!()

      client_id = Application.get_env(:flux_vale, :oauth_device_client_id)
      {:ok, first} = Client.get_by_client_id(client_id, authorize?: false)

      assert :ok == Seeds.seed_oauth_client!()

      {:ok, second} = Client.get_by_client_id(client_id, authorize?: false)
      assert first.id == second.id
      assert first.updated_at == second.updated_at
    end
  end
end
