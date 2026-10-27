defmodule FluxValeWeb.Plugs.AdminEnabled do
  @moduledoc """
  The AshAdmin mount gate (#288, ADR-0027 §2 Am. 1): halts with a bare
  404 while the mount is disabled.

  Same shape as the TestInbox/Storyboard gates: a *runtime* plug, not
  compile-time route mounting — the release is the same image
  everywhere (ADR-0010), the route always compiles in, and
  ADMIN_MOUNT_KEY (runtime.exs) flips the surface on where the fleet
  sets it from BWS. Default-denied: unset is off, and the answer fails
  closed for every plausible "off" shape an operator might write —
  blank values and the obvious falsy literals ("false", "0", "off",
  "no") — so writing ADMIN_MOUNT_KEY=false to disable the surface can
  never enable it.

  The key is a secret on purpose, not a boolean: enabling requires a
  vault write, not an env flip, and its value is never presented
  per-request — the credential is the platform-admin session behind
  this plug (`RequirePlatformAdmin` downstream, ADR-0027 §2's
  route-level auth). The pipeline runs this plug before `:browser`, so
  a closed gate answers before content negotiation, session writes, or
  any header — a disabled surface reveals nothing (the TestInbox
  stance).

  `enabled?/0` is the single answer: the mount's on_mount re-check
  (`FluxValeWeb.AdminGate`) shares it, so the HTTP gate and the socket
  gate cannot fork.
  """

  import Plug.Conn

  @doc false
  @spec init(term()) :: term()
  def init(opts), do: opts

  @doc false
  @spec call(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def call(conn, _opts) do
    if enabled?() do
      conn
    else
      conn
      |> send_resp(:not_found, "Not Found")
      |> halt()
    end
  end

  @doc """
  Whether the mount is on. Fail-closed: unset, whitespace, and
  off-intent literals are off; anything else (a real secret) is on.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    case Application.get_env(:flux_vale, :admin_mount_key) do
      key when is_binary(key) -> affirmative?(String.trim(key))
      _unset -> false
    end
  end

  defp affirmative?(value) do
    value != "" and String.downcase(value) not in ["false", "0", "off", "no"]
  end
end
