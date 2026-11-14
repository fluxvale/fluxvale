defmodule FluxVale.TestSupport.OAuthFixtures do
  @moduledoc false

  # #766 test preconditions: a registered public client, a live user,
  # and the validated authorization request / token pair shapes. All
  # writes ride the domain's actions (AGENTS: test data through
  # actions).

  alias FluxVale.Identity.User
  alias FluxVale.OAuth

  @redirect "http://127.0.0.1:53682/callback"
  @resource "https://mcp.fluxvale.com/mcp"

  def redirect_uri, do: @redirect
  def resource, do: @resource

  def user! do
    User.create!("oauth-#{System.unique_integer([:positive])}@fluxvale.com", %{},
      authorize?: false
    )
  end

  def client!(attrs \\ %{}) do
    params =
      Map.merge(
        %{
          "client_name" => "MCP Test Client",
          "redirect_uris" => [@redirect],
          "scope" => "instances:read offline_access"
        },
        attrs
      )

    {:ok, client} = OAuth.register_client(params)
    client
  end

  def verifier do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  def challenge(verifier) do
    :sha256
    |> :crypto.hash(verifier)
    |> Base.url_encode64(padding: false)
  end

  def authorize_request!(client, user, overrides \\ %{}) do
    verifier = verifier()

    params =
      Map.merge(
        %{
          "client_id" => client.client_id,
          "redirect_uri" => @redirect,
          "response_type" => "code",
          "scope" => "instances:read",
          "code_challenge" => challenge(verifier),
          "code_challenge_method" => "S256",
          "resource" => @resource,
          "state" => "state-#{System.unique_integer([:positive])}"
        },
        overrides
      )

    {:ok, request} = OAuth.validate_authorize_request(params)
    Map.merge(request, %{user: user, verifier: verifier})
  end

  def issue_code!(client, user, overrides \\ %{}) do
    request = authorize_request!(client, user, overrides)
    {:ok, issued} = OAuth.issue_authorization_code(request)
    Map.put(issued, :request, request)
  end

  def tokens!(client, user, overrides \\ %{}) do
    issued = issue_code!(client, user, overrides)

    {:ok, tokens} =
      OAuth.exchange_code(%{
        "code" => issued.code,
        "client_id" => client.client_id,
        "redirect_uri" => @redirect,
        "code_verifier" => issued.request.verifier,
        "resource" => @resource
      })

    %{client: client, user: user, issued: issued, tokens: tokens}
  end
end
