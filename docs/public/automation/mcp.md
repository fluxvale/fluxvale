---
title: MCP server
description: FluxVale hosts an MCP endpoint for agents, with OAuth or a personal access token.
order: 30
slug: mcp
---

FluxVale hosts a Model Context Protocol server for driving the platform from agents and other MCP clients. It is live and early. The tool set may still change shape, so this page stays short until the surface settles.

The endpoint is `https://mcp.fluxvale.com/mcp` (DNS records pending rollout — if the URL doesn't resolve yet, the endpoint is rolling out), speaking the streamable HTTP transport. OAuth-capable clients discover FluxVale's authorization server from the endpoint and open a consent page; clients without OAuth can send a personal access token as the bearer token. The granted scopes decide which tools the server exposes, and destructive tools ask for confirmation before they act.

The full recipe is elsewhere, on purpose — this page stays the summary. The in-app quickstart at [`/settings/agents`](/settings/agents) walks both paths (add the server and approve OAuth, or mint a scoped token for a client without OAuth) with per-client configs. The first-run handoff at [`/docs/agents`](/docs/agents) is the same recipe as one copyable prompt, and [`/llms.txt`](/llms.txt) is its machine-readable entry point. The repo's [`docs/mcp.md`](https://github.com/fluxvale/fluxvale/blob/main/docs/mcp.md) is the tool-surface source of truth (the catalog and the changelog).

Apps take env vars at deploy (`instances_deploy`'s `env` map) and in place afterwards (`instances_configure`'s `set`/`remove`). Values are write-only: the API never echoes them, and the MCP server pins its HTTP/protocol log targets at info so request bodies never reach a log. `apps_show` carries each version's default allocation and `monthly_cents` for the pre-deploy quote, and an instance's detail carries its public `url`.

If you want to try it, create a scoped token and write to [support@fluxvale.com](mailto:support@fluxvale.com) for the current tool list.
