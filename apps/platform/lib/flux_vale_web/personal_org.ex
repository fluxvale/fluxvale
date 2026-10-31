defmodule FluxValeWeb.PersonalOrg do
  @moduledoc """
  The personal org's account posture (owner smoke-test, Oct 30): the
  personal org IS an org under the hood, but presenting it as one is
  weird — it is the user's account. Two halves live here:

    * `personal?/2` — the mount branch every slug-keyed org LiveView
      takes before rendering: when the URL's org IS the actor's personal
      org, the page redirects to the personal account's canonical
      surface instead. Flash-free on purpose: nothing failed, and every
      landing surface self-identifies. A personal slug must never render
      an org page — direct-URL guards included.

    * `org_for/1` — the resolver for the one surface the personal org
      KEEPS under user settings: `/settings/access` (mounted by
      `OrganizationLive.Access` without a slug), which serves the
      personal org's gateway panel. The canonical
      `Accounts.personal_org_for_user/2` is the single source, so this
      can never name a different org than the switcher's Personal row.

  `personal_org_id` itself is resolved by the `FluxValeWeb.OrgNav`
  on_mount, which runs before any of these mounts.

  The guard lives in `mount/3` only. A same-module `live_patch` with
  differing params runs `handle_params/3` — undefined on every org
  LiveView today (the socket dies; pre-existing shape, and no patch
  affordance ships) — so if these pages ever gain patching, the guard
  needs a `handle_params` twin.
  """

  alias FluxVale.Accounts

  @doc """
  True when `org` IS the actor's personal org — the redirect branch's
  only question. Reads OrgNav's `personal_org_id` off the socket.
  """
  @spec personal?(Phoenix.LiveView.Socket.t(), map()) :: boolean()
  def personal?(socket, org) do
    not is_nil(socket.assigns[:personal_org_id]) and org.id == socket.assigns.personal_org_id
  end

  @doc """
  The actor's personal org through the canonical op, actor-authorized.
  `:none` is the seeded/legacy no-org shape (OrgNav's stance) — the
  caller degrades like a not-found.
  """
  @spec org_for(FluxVale.Identity.User.t()) ::
          {:ok, FluxVale.Accounts.Organization.t()} | :none | {:error, term()}
  def org_for(user), do: Accounts.personal_org_for_user(user.id, actor: user)
end
