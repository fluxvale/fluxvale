defmodule FluxValeWeb.ReturnPath do
  @moduledoc """
  The sign-in return path (#462): gated calls to action link
  `/sign-in?return_to=<local path>`, the sign-in LiveView carries the
  value through its one-shot POST, and SessionController redirects
  there on success — the visitor lands back where they were instead of
  the default page.

  The parameter is attacker-controlled input: only local request paths
  ("/"-prefixed, no scheme, no host) may become redirect targets, or
  sign-in would be an open redirect. `local?/1` is the shared
  predicate — the link builder and the session write must never fork
  on the answer. A non-local (or missing) value is silently ignored
  everywhere: every consumer falls back to today's default landing.
  """

  use FluxValeWeb, :verified_routes

  @doc """
  True only for local request paths — safe to redirect to. The refusals
  are the no-host arms: `//evil.com` is protocol-relative, and
  `/\\evil.com` rides the browser's backslash-for-slash normalization
  into the authority slot the same way (verified in Chromium's URL
  parser, #462 review). Any scheme (`https://…`, `javascript:…`) fails
  the leading-slash check outright.

  The trailing `String.contains?/2` arms mirror the validators this
  value meets downstream: a backslash anywhere, or a `/%09`/tab-after-
  slash substring, would raise in Phoenix's `redirect(to:)`; a newline
  or carriage return raises in Plug's header write. This predicate must
  be *sufficient*, not just necessary — anything it admits, the
  redirect chain accepts.
  """
  @spec local?(term()) :: boolean()
  def local?(path) when is_binary(path) do
    String.starts_with?(path, "/") and not String.starts_with?(path, "//") and
      not String.starts_with?(path, "/\\") and
      not String.contains?(path, ["\\", "/%09", "/\t", "\n", "\r"])
  end

  def local?(_path), do: false

  @doc """
  The path when local, nil otherwise — the silent-ignore fallback.
  """
  @spec safe(term()) :: String.t() | nil
  def safe(path) do
    if local?(path), do: path
  end

  @doc """
  The sign-in link for a return target: carries `?return_to=` when the
  target is local, plain `/sign-in` otherwise (nil included).
  """
  @spec sign_in_path(term()) :: String.t()
  def sign_in_path(target) do
    case safe(target) do
      nil -> ~p"/sign-in"
      path -> ~p"/sign-in?return_to=#{path}"
    end
  end

  @doc """
  The code step's link for a return target (#219): the native POST's
  PRG target and the failed-verify retry both land here. Same rule as
  `sign_in_path/1` — a local target rides the query, anything else is
  dropped.
  """
  @spec code_path(term()) :: String.t()
  def code_path(target) do
    case safe(target) do
      nil -> ~p"/sign-in/code"
      path -> ~p"/sign-in/code?return_to=#{path}"
    end
  end
end
