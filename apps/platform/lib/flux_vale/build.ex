defmodule FluxVale.Build do
  @moduledoc """
  Build identity, injected via `BUILD_SHA` at image-build time.

  `version/0` reports `"sha-<sha>"` when a SHA is present (the deploy
  pipeline polls `/health` until `version == sha-<sha>` — see
  docs/deployment.md), or `"dev"` for local/`mix phx.server` runs.
  """

  @spec version :: String.t()
  def version do
    case Application.get_env(:flux_vale, :build_sha) do
      sha when is_binary(sha) and sha != "" -> "sha-" <> sha
      _other -> "dev"
    end
  end
end
