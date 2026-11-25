---
title: MCP server
description: FluxVale hosts an MCP endpoint for agents, with OAuth, the CLI, or a personal access token.
order: 30
slug: mcp
---

FluxVale hosts a Model Context Protocol server for driving the platform from agents and other MCP clients. It is live and early. The tool set may still change shape, so this page stays short until the surface settles.

The endpoint is `https://mcp.fluxvale.com/mcp`, speaking the streamable HTTP transport. OAuth-capable clients discover FluxVale's authorization server from the endpoint and open a consent page. On a machine with no browser, the `fluxvale` CLI bridges a local client (sign in with `fluxvale mcp login`, connect with `fluxvale mcp serve`). Clients without OAuth can send a personal access token as the bearer token. The granted scopes decide which tools the server exposes, and destructive tools ask for confirmation before they act.

The full recipe lives elsewhere on purpose, so this page stays a short summary. The in-app quickstart at [`/settings/agents`](/settings/agents) walks every path (add the server and approve OAuth, bridge a remote machine with the CLI, or mint a scoped token for a client without OAuth) with per-client configs. The guide at [`/docs/agents`](/docs/agents) explains the setup. The copyable prompt is in the dashboard once you're signed in (the `/agent` panel and the first-run modal both render it), and [`/llms.txt`](/llms.txt) is its machine-readable entry point. The repo's [`docs/mcp.md`](https://github.com/fluxvale/fluxvale/blob/main/docs/mcp.md) is the tool-surface source of truth (the catalog and the changelog).

Apps take env vars at deploy (`instances_deploy`'s `env` map) and in place afterwards (`instances_configure`'s `set`/`remove`). Values are write-only: the API never echoes them, and the MCP server pins its HTTP/protocol log targets at info so request bodies never reach a log. `apps_show` carries each version's default allocation and `monthly_cents` for the pre-deploy quote, and an instance's detail carries its public `url`.

For the full tool catalog and changelog, see [`docs/mcp.md`](https://github.com/fluxvale/fluxvale/blob/main/docs/mcp.md). For questions or feedback, write to [support@fluxvale.com](mailto:support@fluxvale.com).
