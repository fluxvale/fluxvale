---
title: MCP server
description: FluxVale hosts an MCP endpoint for agents, secured by a personal access token.
order: 30
slug: mcp
---

FluxVale hosts a Model Context Protocol server for driving the platform from agents and other MCP clients. It is live and early. The tool set may still change shape, so this page stays short until the surface settles.

The endpoint is `https://fluxvale.com/mcp`, speaking the streamable HTTP transport. Authentication is a personal access token used as a bearer token. The token's scopes decide which tools the server exposes, and destructive tools ask for confirmation before they act.

If you want to try it, create a scoped token and write to [support@fluxvale.com](mailto:support@fluxvale.com) for the current tool list.
