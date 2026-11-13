defmodule FluxValeWeb.AgentPrompt do
  @moduledoc """
  The post-signup handoff's one source of truth (#765): the prompt an
  agent follows to finish setup, the per-client install snippets, and
  the machine-readable `llms.txt` body.

  Three surfaces render from here — the `/agent` panel (org-specific),
  `/docs/agents` (generic), and `/llms.txt` (generic) — so the prompt
  cannot fork. The public contexts carry placeholder org values; the
  panel carries the signed-in user's personal org.

  Auth is one swappable setting. `:pat` is today's shape: the prompt
  names the token mint and the snippets carry a `FLUXVALE_PAT` bearer
  header. Set `:mcp_auth_mode` to `:oauth` when the MCP OAuth slice
  lands (#766) — the note and every snippet's header drop together.
  Values are never echoed: the snippets carry only env-var references,
  and no function here receives a minted token.
  """

  use FluxValeWeb, :verified_routes

  @auth_mode_default :pat

  @scopes "catalog:read, instances:write, backups:write, wallet:read"

  @auth_note_pat """
  Mint a scoped token at %{token_url} with scopes %{scopes}, export it as \
  `FLUXVALE_PAT`, and send it as `Authorization: Bearer $FLUXVALE_PAT` on the \
  MCP connection. A client that speaks OAuth will open a browser sign-in \
  instead once OAuth ships.\
  """

  @auth_note_oauth """
  Your client opens a browser sign-in to FluxVale on first connect — no \
  token to paste.\
  """

  @commit_rule "Confirm the spend with me before deploying. Never deploy without an explicit yes."

  defstruct [:org_name, :org_slug, :api_base, :mcp_url]

  @type t :: %__MODULE__{
          org_name: String.t(),
          org_slug: String.t(),
          api_base: String.t(),
          mcp_url: String.t()
        }

  @doc "The public, org-agnostic context — `/docs/agents` and `/llms.txt`."
  @spec public_context() :: t()
  def public_context do
    %__MODULE__{
      org_name: "your organization",
      org_slug: "<your-org-slug>",
      api_base: FluxValeWeb.Endpoint.url(),
      mcp_url: mcp_url()
    }
  end

  @doc "The signed-in user's context — the `/agent` panel."
  @spec context(String.t() | nil, String.t() | nil) :: t()
  def context(org_name, org_slug) do
    %__MODULE__{
      org_name: org_name || "your organization",
      org_slug: org_slug || "<your-org-slug>",
      api_base: FluxValeWeb.Endpoint.url(),
      mcp_url: mcp_url()
    }
  end

  @doc "The configured MCP endpoint (prod, staging, or the local k3d host)."
  @spec mcp_url() :: String.t()
  def mcp_url, do: Application.fetch_env!(:flux_vale, :mcp_server_url)

  @doc "The scopes the prompt asks the user to mint."
  @spec scopes() :: String.t()
  def scopes, do: @scopes

  @doc "The one auth sentence — PAT today, browser sign-in once OAuth ships."
  @spec auth_note(t()) :: String.t()
  def auth_note(%__MODULE__{} = ctx) do
    case auth_mode() do
      :pat ->
        @auth_note_pat
        |> String.replace("%{token_url}", token_url(ctx))
        |> String.replace("%{scopes}", scopes())

      :oauth ->
        @auth_note_oauth
    end
  end

  @doc "True while the snippets must carry a bearer header."
  @spec bearer_headers?() :: boolean()
  def bearer_headers?, do: auth_mode() == :pat

  @doc """
  The auth-copy mode: `:pat` (the current token mint) or `:oauth` (the
  browser sign-in handshake). One setting drives the note and every
  snippet's header, so the switch cannot half-land.
  """
  @spec auth_mode() :: :pat | :oauth
  def auth_mode, do: Application.get_env(:flux_vale, :mcp_auth_mode, @auth_mode_default)

  @doc "The generated prompt — the panel, `/docs/agents`, and `/llms.txt`."
  @spec prompt(t()) :: String.t()
  def prompt(%__MODULE__{} = ctx) do
    """
    Finish setup with your agent.

    FluxVale org: #{ctx.org_name} (#{ctx.org_slug})
    API base: #{ctx.api_base}
    MCP server: #{ctx.mcp_url}

    Auth: #{auth_note(ctx)}

    You are my FluxVale setup agent. Connect to the MCP server above, then:
    1. Call `whoami`, then `wallet_balance`. If the balance is zero or negative, stop and give me the top-up link: #{ctx.api_base}#{~p"/billing/topup"}. Do not deploy.
    2. Ask what I want to run, then propose one app from `apps_list` with the CPU, memory, and storage you recommend, plus its hourly cost (`wallet_runway` shows the burn).
    3. #{@commit_rule}
    4. Deploy with `instances_deploy`. Put configuration in `env`, for example {"TZ":"UTC"}.
    5. Poll `instances_status` until it is running, then give me the instance URL.
    6. Change env later with `instances_configure`: `set` adds or replaces, `remove` deletes. Values are write-only — never print them.
    7. Never run `instances_destroy` or `backups_restore` without a separate, explicit yes.
    8. After the app runs, offer Terraform if I want to manage it as code: #{ctx.api_base}#{~p"/docs/automation/terraform"}.

    Reference: #{ctx.api_base}#{~p"/docs/agents"}
    """
  end

  @doc "What the panel promises the agent will do, in order."
  @spec what_it_will_do() :: [String.t()]
  def what_it_will_do do
    [
      "Check your wallet and stop at zero",
      "Propose an app with its size and hourly cost",
      "Confirm the spend before deploying",
      "Deploy and set env vars",
      "Verify the instance URL",
      "Ask before anything destructive"
    ]
  end

  @doc "The spend rule, standalone for the panel's callout."
  @spec commit_rule() :: String.t()
  def commit_rule, do: @commit_rule

  @doc "One client's install snippet by key."
  @spec install(:claude_code | :cursor | :vscode | :generic, t()) :: String.t()
  def install(:claude_code, %__MODULE__{} = ctx) do
    command = "claude mcp add --transport http fluxvale #{ctx.mcp_url}"

    if bearer_headers?() do
      command <> ~s( \\\n  --header "Authorization: Bearer $FLUXVALE_PAT")
    else
      command
    end
  end

  def install(:cursor, %__MODULE__{} = ctx) do
    config = headers(%{"url" => ctx.mcp_url, "type" => "http"})
    json = Jason.encode!(config)
    encoded = Base.encode64(json)

    "cursor://anysphere.cursor-deeplink/mcp/install?name=fluxvale&config=" <>
      URI.encode_www_form(encoded)
  end

  def install(:vscode, %__MODULE__{} = ctx) do
    Jason.encode!(
      %{"servers" => %{"fluxvale" => headers(%{"type" => "http", "url" => ctx.mcp_url})}},
      pretty: true
    )
  end

  def install(:generic, %__MODULE__{} = ctx) do
    Jason.encode!(
      %{"mcpServers" => %{"fluxvale" => headers(%{"type" => "http", "url" => ctx.mcp_url})}},
      pretty: true
    )
  end

  @doc "The doc links every surface carries — stable, same-environment URLs."
  @spec links(t()) :: [{String.t(), String.t()}]
  def links(%__MODULE__{} = ctx) do
    [
      {"Agent setup", ctx.api_base <> ~p"/docs/agents"},
      {"MCP server", ctx.api_base <> ~p"/docs/automation/mcp"},
      {"CLI quickstart", ctx.api_base <> ~p"/docs/automation/cli"},
      {"Terraform provider", ctx.api_base <> ~p"/docs/automation/terraform"}
    ]
  end

  @doc "The machine-readable `/llms.txt` body."
  @spec llms_txt(t()) :: String.t()
  def llms_txt(%__MODULE__{} = ctx) do
    doc_links = links(ctx)
    rendered_links = Enum.map_join(doc_links, "\n", fn {title, url} -> "- [#{title}](#{url})" end)

    """
    # FluxVale

    > FluxVale deploys open-source apps as managed cloud instances. An agent can \
    finish a new account's setup over the FluxVale MCP server.

    ## Set up with your agent

    #{prompt(ctx)}

    ## Links

    #{rendered_links}
    """
  end

  defp token_url(%__MODULE__{} = ctx),
    do: ctx.api_base <> ~p"/settings/developer#api-tokens"

  defp headers(config) do
    if bearer_headers?() do
      Map.put(config, "headers", %{"Authorization" => "Bearer ${env:FLUXVALE_PAT}"})
    else
      config
    end
  end
end
