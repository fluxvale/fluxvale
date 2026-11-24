defmodule FluxValeWeb.DeveloperSettingsLive do
  @moduledoc """
  Developer settings (#635): the account's developer tooling — the
  Device sign-ins (#362 T3) and API tokens (#483) sections, moved
  here from /settings/access so the access page keeps only the
  private-access gateway panel it is named for.

  Actor-scoped like the settings cluster: no org resolves at mount,
  so the page works for every signed-in actor (in the sidebar, Profile
  and Developer are the ungated entries; Access and Wallet ride the
  personal-org gate). The device flow's verification_uri landing
  (/settings/access/device) redirects here at the #device-sign-ins
  anchor, and the section ids keep their old names —
  verification_uri_complete-style links against THIS page resolve
  against the same targets. A fragment on the old /settings/access
  URL can never be redirected (fragments never reach the server); the
  path-level landing covers the link the system itself mints.

  Device sign-ins: the actor's pending requests — approve binds the
  row to the clicking user and the CLI's next poll mints the PAT for
  them; deny leaves it refused. Rows are unattributed until an
  approval binds one (the human compares the on-screen user_code
  with their terminal's before clicking, the gh posture).

  API tokens: the actor's own PATs — create (name + a per-domain
  access level off the grouped picker, #892), the raw value shown
  once at creation, and revoke, effective immediately. Self-service
  by construction: the reads and writes ride the owner-scoped
  policies. The section links the agent quickstart (#484 W5,
  /settings/agents) — the MCP recipe one click from the mint,
  wherever the mint lives.

  Connected apps (#766): the MCP clients the actor approved through
  OAuth, one row per token family. Disconnect revokes the whole family;
  the next MCP call presents a revoked token and gets 401.
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Api.Scopes
  alias FluxVale.Identity
  alias FluxVale.Identity.DeviceCode
  alias FluxVale.Identity.PersonalAccessToken
  alias FluxVale.OAuth
  alias FluxValeWeb.AccountSettings

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> stream_configure(:device_sign_ins, dom_id: &"device-sign-in-#{&1.id}")
     |> stream_configure(:api_tokens, dom_id: &"api-token-#{&1.id}")
     |> stream_configure(:oauth_connections, dom_id: &"oauth-connection-#{&1.family_id}")
     |> assign(fresh_token: nil, token_revoke_armed_id: nil, token_form_key: 0)
     |> assign(oauth_disconnect_armed_id: nil)
     |> assign(token_form: to_form(%{"name" => ""}, as: "token", id: "api-token-form-0"))
     |> assign(scope_domains: Scopes.domains(), scope_levels: Scopes.default_levels())
     |> refresh_device_sign_ins()
     |> refresh_oauth_connections()
     |> refresh_api_tokens()}
  end

  # ---- Device sign-ins (#362 T3): approve / deny the device flow ----

  @impl Phoenix.LiveView
  # Approve binds the row to the CLICKING user (the :approve action's
  # contract — the argument rides the actor, never form params), and
  # the CLI's next poll mints the PAT for them. The stale arms (the
  # row was approved/denied elsewhere, or expired, between render and
  # click) find nothing pending and converge through the refetch —
  # a crafted click's no-op posture.
  def handle_event("approve-device", %{"id" => id}, socket) do
    case find_pending_device_sign_in(socket, id) do
      nil ->
        {:noreply, device_sign_in_gone(socket)}

      code ->
        case DeviceCode.approve(code, actor: socket.assigns.current_user) do
          {:ok, _approved} ->
            {:noreply,
             socket
             |> put_flash(
               :info,
               "Device approved. Finish the sign-in from your terminal."
             )
             |> refresh_device_sign_ins()}

          # The filtered write lost a race the pending re-read missed
          # (deny/consume landed between the read and the write).
          # coveralls-ignore-start - needs the row to transition inside
          # this handler's read→write window — an in-process race the
          # suite cannot order; the nil arm above is the testable shape.
          {:error, _stale} ->
            {:noreply, device_sign_in_gone(socket)}

            # coveralls-ignore-stop
        end
    end
  end

  def handle_event("deny-device", %{"id" => id}, socket) do
    case find_pending_device_sign_in(socket, id) do
      nil ->
        {:noreply, device_sign_in_gone(socket)}

      code ->
        case DeviceCode.deny(code, actor: socket.assigns.current_user) do
          {:ok, _denied} ->
            {:noreply,
             socket
             |> put_flash(:info, "Device sign-in denied.")
             |> refresh_device_sign_ins()}

          # coveralls-ignore-start - same race arm as approve's, same
          # posture.
          {:error, _stale} ->
            {:noreply, device_sign_in_gone(socket)}

            # coveralls-ignore-stop
        end
    end
  end

  # ---- Connected apps (#766): the OAuth token families ----

  def handle_event("arm-oauth-disconnect", %{"id" => family_id}, socket)
      when is_binary(family_id) do
    {:noreply,
     socket
     |> assign(oauth_disconnect_armed_id: family_id)
     |> refresh_oauth_connections()}
  end

  def handle_event("arm-oauth-disconnect", _params, socket), do: {:noreply, socket}

  def handle_event("cancel-oauth-disconnect", _params, socket) do
    {:noreply,
     socket
     |> assign(oauth_disconnect_armed_id: nil)
     |> refresh_oauth_connections()}
  end

  def handle_event("disconnect-oauth", %{"id" => family_id}, socket)
      when is_binary(family_id) do
    if socket.assigns.oauth_disconnect_armed_id == family_id do
      case OAuth.revoke_connection(socket.assigns.current_user, family_id) do
        {:ok, _count} ->
          {:noreply,
           socket
           |> put_flash(:info, "Disconnected. That app's next request will be refused.")
           |> assign(oauth_disconnect_armed_id: nil)
           |> refresh_oauth_connections()}

        # coveralls-ignore-start - the owner read/revoke failing is a DB
        # outage; the flash is the honest retry arm.
        {:error, _refused} ->
          {:noreply,
           socket
           |> put_flash(:error, "Couldn't disconnect the app. Refresh and try again.")
           |> assign(oauth_disconnect_armed_id: nil)
           |> refresh_oauth_connections()}

          # coveralls-ignore-stop
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("disconnect-oauth", _params, socket), do: {:noreply, socket}

  # ---- API tokens (#483): create, list, revoke the actor's own PATs ----

  # The picker's change events keep the server state aligned with the
  # radios (#892): the typed name rides along (the form's source data,
  # so a re-render never wipes it) and each {domain, level} entry is
  # folded in only when it expands cleanly — a crafted or stale entry
  # is ignored, so @scope_levels is always valid and the summary always
  # renders from Scopes.scopes_for_levels/1.
  def handle_event("scope-change", %{"token" => params}, socket) when is_map(params) do
    form =
      to_form(
        %{"name" => raw_name_from(params)},
        as: "token",
        id: "api-token-form-#{socket.assigns.token_form_key}"
      )

    levels = merge_scope_levels(socket.assigns.scope_levels, Map.get(params, "domain_levels"))

    {:noreply, assign(socket, token_form: form, scope_levels: levels)}
  end

  # A crafted change without a form payload is a no-op, never a crash.
  def handle_event("scope-change", _params, socket), do: {:noreply, socket}

  # The create rides the MintPat operation (the domain is the seam):
  # the picker's levels expand to catalog scopes (Scopes.scopes_for_levels/1
  # validates every entry first), the hash-only write, the raw value
  # back exactly once. The picker can only submit levels its own change
  # handler accepted, so an off-catalog scope can only arrive crafted —
  # the expansion refuses it before anything is generated. Every level
  # at "none" is a valid mint (the scopeless routes).
  def handle_event("create-token", %{"token" => params}, socket) when is_map(params) do
    user = socket.assigns.current_user
    name = name_from(params)

    if name == "" do
      {:noreply, put_flash(socket, :error, "Give the token a name first.")}
    else
      levels = Map.get(params, "domain_levels", %{})

      case Scopes.scopes_for_levels(levels) do
        {:ok, scopes} -> mint_token(socket, user, name, scopes)
        {:error, {:invalid_scope, _scope}} -> invalid_selection_flash(socket)
      end
    end
  end

  # A crafted submit without the form payload is a no-op, never a
  # crash — wrong-typed payloads included: a non-map token or a
  # non-binary name lands in the empty-name refusal, never an
  # exception.
  def handle_event("create-token", _params, socket), do: {:noreply, socket}

  # The reveal is the raw value's only rendering. Dismissal clears the
  # assign — the only live copy — and nothing can render it again: the
  # operation keeps no raw, the row keeps the hash.
  def handle_event("dismiss-token-reveal", _params, socket) do
    {:noreply, assign(socket, :fresh_token, nil)}
  end

  # Revoke rides the armed posture (the gateway remove family): only an
  # armed id revokes, and it must match the clicked row, so a crafted
  # click without arming is a no-op. The arm and cancel refetch the
  # stream — a stream item re-renders only through a stream operation,
  # so the assign alone would leave the row stale. The operation is the
  # authority — its id lookup is owner-gated, so a forged id for
  # another user's token is refused by the policy, not the UI.
  def handle_event("arm-token-revoke", %{"id" => id}, socket) when is_binary(id) do
    {:noreply,
     socket
     |> assign(token_revoke_armed_id: id)
     |> refresh_api_tokens()}
  end

  def handle_event("arm-token-revoke", _params, socket), do: {:noreply, socket}

  def handle_event("cancel-token-revoke", _params, socket) do
    {:noreply,
     socket
     |> assign(token_revoke_armed_id: nil)
     |> refresh_api_tokens()}
  end

  def handle_event("revoke-token", %{"id" => id}, socket) when is_binary(id) do
    if socket.assigns.token_revoke_armed_id == id do
      case Identity.revoke_pat(socket.assigns.current_user, id) do
        {:ok, _revoked} ->
          {:noreply,
           socket
           |> put_flash(:info, "Token revoked. Anything using it stops working now.")
           |> assign(token_revoke_armed_id: nil)
           |> refresh_api_tokens()}

        # A policy refusal (a forged id for another user's token) or a
        # lost race against a concurrent sever — one honest line and the
        # refetch, the stale posture.
        {:error, _refused} ->
          {:noreply,
           socket
           |> put_flash(:error, "Couldn't revoke the token. Refresh and try again.")
           |> assign(token_revoke_armed_id: nil)
           |> refresh_api_tokens()}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("revoke-token", _params, socket), do: {:noreply, socket}

  # Only a still-pending row acts — the pending re-read IS the guard
  # (the :pending read filters status and expiry), so a crafted or
  # stale id is a quiet no-op + refresh, never a crash.
  defp find_pending_device_sign_in(socket, id) do
    pending = DeviceCode.pending!(actor: socket.assigns.current_user)
    Enum.find(pending, &(&1.id == id))
  end

  defp device_sign_in_gone(socket) do
    socket
    |> put_flash(:error, "That sign-in request is no longer pending.")
    |> refresh_device_sign_ins()
  end

  # The actor's pending sign-in requests — rows are unattributed until
  # an approval binds one to the clicking user; the human compares the
  # on-screen user_code with their terminal's before clicking, the gh
  # posture.
  defp refresh_device_sign_ins(socket) do
    pending = DeviceCode.pending!(actor: socket.assigns.current_user)

    socket
    |> stream(:device_sign_ins, pending, reset: true)
    |> assign(device_sign_ins_empty?: pending == [])
  end

  # The actor's live OAuth families, newest first — the domain op
  # groups the token rows and attaches the registered client's name.
  defp refresh_oauth_connections(socket) do
    user = socket.assigns.current_user

    # coveralls-ignore-start - the owner read failing is a DB outage;
    # the empty list is the honest degraded arm.
    connections =
      case OAuth.list_connections(user) do
        {:ok, connections} -> connections
        {:error, _refused} -> []
      end

    # coveralls-ignore-stop

    socket
    |> stream(:oauth_connections, connections, reset: true)
    |> assign(oauth_connections_empty?: connections == [])
  end

  # The actor's own rows, newest first — DateTime.compare/2 is the
  # chronological comparison (term ordering on the structs orders map
  # keys alphabetically, microsecond before second, and would scramble
  # anything within the same minute). The id breaks same-instant ties.
  # The read policy scopes to the owner (user_id == actor.id) and the
  # filter argument names the same user, so the bang cannot meet a
  # refusal.
  defp refresh_api_tokens(socket) do
    user = socket.assigns.current_user

    tokens =
      user.id
      |> PersonalAccessToken.list_for_user!(actor: user)
      |> Enum.sort(fn left, right ->
        case DateTime.compare(left.created_at, right.created_at) do
          :gt -> true
          :eq -> left.id >= right.id
          :lt -> false
        end
      end)

    socket
    |> stream(:api_tokens, tokens, reset: true)
    |> assign(api_tokens_empty?: tokens == [])
  end

  # A successful mint re-keys the form. The typed name lives in the
  # input's dirty value, which a value-attribute patch cannot clear
  # (HTML default-value semantics) — the radios are likewise
  # uncontrolled — so a plain re-assign would leave the submission
  # armed for a duplicate mint on the next click. A changed id replaces
  # the whole form subtree: fresh inputs, server-rendered defaults.
  # The level map resets with it (the fresh radios render "none"
  # everywhere), so the summary matches what the new form shows. A
  # FAILED submit keeps the key and the levels, so the user fixes the
  # name instead of starting over.
  defp assign_new_form_key(socket) do
    key = socket.assigns.token_form_key + 1

    socket
    |> assign(token_form_key: key)
    |> assign(token_form: to_form(%{"name" => ""}, as: "token", id: "api-token-form-#{key}"))
    |> assign(scope_levels: Scopes.default_levels())
  end

  defp name_from(%{"name" => name}) when is_binary(name), do: String.trim(name)
  defp name_from(_params), do: ""

  # The change event's raw name for the form's source data — no trim
  # (the input keeps exactly what was typed), unlike the create path.
  defp raw_name_from(%{"name" => name}) when is_binary(name), do: name
  defp raw_name_from(_params), do: ""

  # Fold crafted-safe: an entry rides only when its {domain, level}
  # expands to catalog scopes; anything else (unknown domain, unknown
  # level, write on a read-only domain, a non-map payload) leaves the
  # current levels standing — @scope_levels can never hold an invalid
  # entry, so the picker's render and the create's expansion always
  # agree.
  defp merge_scope_levels(current, levels) when is_map(levels) do
    Enum.reduce(levels, current, fn {domain, level}, acc ->
      outcome = Scopes.scopes_for_level(domain, level)

      case outcome do
        {:ok, _scopes} -> Map.put(acc, domain, level)
        {:error, _invalid} -> acc
      end
    end)
  end

  defp merge_scope_levels(current, _levels), do: current

  # The mint's own depth: the level expansion in the create handler,
  # the result mapping here. The expansion only returns catalog
  # scopes, so the operation's scope-validation refusal cannot fire —
  # whatever error comes back is a name/policy refusal.
  defp mint_token(socket, user, name, scopes) do
    case Identity.mint_pat(user, %{user_id: user.id, name: name, scopes: scopes}) do
      {:ok, %{token: raw, pat: pat}} ->
        {:noreply,
         socket
         |> assign(fresh_token: %{id: pat.id, name: pat.name, token: raw})
         |> assign_new_form_key()
         |> refresh_api_tokens()}

      {:error, _refused} ->
        {:noreply,
         put_flash(socket, :error, "Couldn't create the token. Check the name and try again.")}
    end
  end

  defp invalid_selection_flash(socket) do
    {:noreply,
     put_flash(
       socket,
       :error,
       "Couldn't create the token. The scope selection wasn't valid. Refresh and try again."
     )}
  end

  # ---- Connected apps copy ----

  defp connection_scope_line(%{scopes: []}), do: "no scopes (identity only)"
  defp connection_scope_line(%{scopes: scopes}), do: Enum.join(scopes, ", ")

  defp connection_resource(%{resource: nil}), do: "No resource"

  defp connection_resource(%{resource: resource}) do
    case URI.parse(resource).authority do
      nil -> resource
      authority -> authority
    end
  end

  defp connection_last_used(%{last_used_at: nil}), do: "Never used"

  defp connection_last_used(%{last_used_at: last_used_at}) do
    "Last used " <> Calendar.strftime(last_used_at, "%b %d, %Y")
  end

  # ---- API tokens copy ----

  # Revocation is the instant sever, expiry the quiet one — revoked
  # wins when both hold (the row is dead either way, the copy says how).
  defp token_status(%PersonalAccessToken{revoked_at: revoked_at}) when not is_nil(revoked_at),
    do: :revoked

  defp token_status(%PersonalAccessToken{} = token) do
    if DateTime.compare(token.expires_at, DateTime.utc_now()) == :lt do
      :expired
    else
      :active
    end
  end

  # Empty scopes grants the scopeless routes only (the boundary plug's
  # :any rows) — say so, never the device flow's "full access" wording.
  defp scopes_line(%PersonalAccessToken{scopes: []}), do: "no scopes (identity only)"
  defp scopes_line(%PersonalAccessToken{scopes: scopes}), do: Enum.join(scopes, ", ")

  defp last_used_line(%PersonalAccessToken{last_used_at: nil}), do: "Never used"

  defp last_used_line(%PersonalAccessToken{last_used_at: last_used_at}) do
    "Last used " <> Calendar.strftime(last_used_at, "%b %d, %Y")
  end

  # Mint provenance is system-written (#362): the device flow's rows
  # carry minted_via "device", the panel's own mints carry nothing.
  defp device_minted?(%PersonalAccessToken{metadata: %{"minted_via" => "device"}}), do: true
  defp device_minted?(%PersonalAccessToken{}), do: false

  # The scopes the current level map mints, in catalog order. The map
  # is merge_scope_levels/2's output — always valid — so the expansion
  # cannot fail and the summary renders from the same seam the create
  # validates with.
  defp selected_scopes(scope_levels) do
    {:ok, scopes} = Scopes.scopes_for_levels(scope_levels)
    scopes
  end

  # The selector track's grid: three equal columns for a writable
  # domain, two narrower ones for a read-only domain so its No access
  # and Read columns line up with the writable rows' columns.
  defp segment_grid_classes(%{writable?: true}), do: "grid grid-cols-3 gap-1"

  defp segment_grid_classes(%{writable?: false}), do: "grid grid-cols-2 gap-1 sm:w-2/3"

  # ---- Device sign-ins copy (#362) ----

  # Empty scopes is the catalog's "full access" shape (OQ #9's
  # single first-party client) — say so plainly; a scoped request
  # names its entries.
  defp scope_line(%DeviceCode{scopes: []}), do: "all scopes (full access)"
  defp scope_line(%DeviceCode{scopes: scopes}), do: Enum.join(scopes, ", ")

  defp device_client_label(%DeviceCode{client_id: client_id}), do: "client #{client_id}"

  defp expires_in_label(%DeviceCode{expires_at: expires_at}) do
    expires_at
    |> DateTime.diff(DateTime.utc_now(), :minute)
    |> max(0)
    |> then(&"#{&1} min")
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      actor_orgs={@actor_orgs}
      personal_org_id={@personal_org_id}
      username={@username}
      nav_section={@nav_section}
      bare
    >
      <%!-- App-wide grammar page (S10): `bare` main + .appgram — the
      page owns ALL of main's rhythm, the access page's personal
      frame verbatim. --%>
      <div class="appgram contents">
        <section class="band">
          <div class="wrap pt-8 pb-10">
            <div class="rise">
              <.link
                navigate={~p"/settings"}
                data-testid="settings-developer-back"
                class="inline-flex items-center gap-1.5 text-sm text-ink-muted transition-colors hover:text-ink"
              >
                <span aria-hidden="true">&larr;</span> Settings
              </.link>
              <div class="mt-3 min-w-0">
                <h1 class="page-title mt-1.5" data-testid="settings-title">
                  Account settings
                </h1>
              </div>
            </div>
          </div>
        </section>

        <section class="wrap pt-8 pb-16">
          <div class="rise flex flex-col gap-8 md:flex-row md:gap-12">
            <%!-- #551: the account cluster's section sidebar — the
            Developer entry is this page's own. --%>
            <AccountSettings.sidebar current="developer" personal_org_id={@personal_org_id} />

            <div class="min-w-0 flex-1 space-y-6">
              <div>
                <h2 class="text-base font-medium text-ink" data-testid="developer-heading">
                  Developer
                </h2>
                <p class="mt-1 text-sm text-ink-muted">
                  The tools that act for your account on the machine API.
                </p>
              </div>

              <%!-- #362: the device flow's approval surface — the actor's
                pending sign-in requests. The rows are unattributed
                until an approval binds one to the clicking user; the
                copy carries the human check (compare the code with
                your terminal). Section id is the verification_uri
                fragment's target (the /settings/access/device landing
                redirects here). --%>
              <div class="space-y-3" id="device-sign-ins" data-testid="device-sign-ins">
                <div>
                  <h3 class="text-sm font-medium text-ink-muted">Device sign-ins</h3>
                  <p class="mt-1 text-sm text-ink-muted">
                    Signing in to the FluxVale CLI? Approve the request whose code matches
                    your terminal. The CLI token is minted for your account.
                  </p>
                </div>

                <div class="mono-panel min-w-0">
                  <p
                    :if={@device_sign_ins_empty?}
                    class="font-sans text-sm text-ink-muted"
                    data-testid="device-sign-ins-empty"
                  >
                    No device sign-ins waiting.
                  </p>

                  <ul id="device-sign-in-rows" phx-update="stream" class="divide-y divide-line">
                    <li
                      :for={{dom_id, code} <- @streams.device_sign_ins}
                      id={dom_id}
                      class="flex flex-wrap items-center justify-between gap-3 py-3 first:pt-0 last:pb-0"
                      data-testid="device-sign-in-row"
                    >
                      <div class="min-w-0 space-y-1">
                        <p
                          class="font-mono text-sm font-medium text-ink"
                          data-testid="device-user-code"
                        >
                          {code.user_code}
                        </p>
                        <p class="text-xs text-ink-muted" data-testid="device-meta">
                          {scope_line(code)}: {device_client_label(code)}, expires in {expires_in_label(
                            code
                          )}
                        </p>
                      </div>
                      <div class="flex gap-3">
                        <.button
                          type="button"
                          phx-click="approve-device"
                          phx-value-id={code.id}
                          size="sm"
                          data-testid="device-approve"
                        >
                          Approve
                        </.button>
                        <.button
                          type="button"
                          phx-click="deny-device"
                          phx-value-id={code.id}
                          variant="ghost"
                          size="sm"
                          data-testid="device-deny"
                        >
                          Deny
                        </.button>
                      </div>
                    </li>
                  </ul>
                </div>
              </div>

              <%!-- #766: the MCP clients approved through OAuth — one
                row per token family. Disconnect revokes the whole
                family; the next MCP call gets 401. --%>
              <div class="space-y-3" id="connected-apps" data-testid="connected-apps">
                <div>
                  <h3 class="text-sm font-medium text-ink-muted">Connected apps</h3>
                  <p class="mt-1 text-sm text-ink-muted">
                    Apps you approved through OAuth. They can act as you within the scopes
                    shown; disconnecting revokes their tokens immediately.
                  </p>
                </div>

                <div class="mono-panel min-w-0">
                  <p
                    :if={@oauth_connections_empty?}
                    class="font-sans text-sm text-ink-muted"
                    data-testid="oauth-connections-empty"
                  >
                    No connected apps yet. An MCP client appears here after you approve it.
                  </p>

                  <ul id="oauth-connection-rows" phx-update="stream" class="divide-y divide-line">
                    <li
                      :for={{dom_id, connection} <- @streams.oauth_connections}
                      id={dom_id}
                      class="space-y-1.5 py-3 first:pt-0 last:pb-0"
                      data-testid="oauth-connection-row"
                    >
                      <div class="flex flex-wrap items-center justify-between gap-3">
                        <div class="min-w-0 space-y-1">
                          <p
                            class="font-mono text-sm font-medium text-ink"
                            data-testid="oauth-connection-client"
                          >
                            {connection.client_name}
                          </p>
                          <p
                            class="font-sans text-xs text-ink-muted"
                            data-testid="oauth-connection-meta"
                          >
                            <span class="font-mono">{connection_scope_line(connection)}</span>
                            · {connection_resource(connection)} · Created {Calendar.strftime(
                              connection.created_at,
                              "%b %d, %Y"
                            )} · {connection_last_used(connection)}
                          </p>
                        </div>

                        <.button
                          :if={@oauth_disconnect_armed_id != connection.family_id}
                          type="button"
                          phx-click="arm-oauth-disconnect"
                          phx-value-id={connection.family_id}
                          variant="ghost"
                          size="sm"
                          data-testid="oauth-disconnect"
                        >
                          Disconnect
                        </.button>
                      </div>

                      <.callout
                        :if={@oauth_disconnect_armed_id == connection.family_id}
                        id={"oauth-disconnect-confirm-#{connection.family_id}"}
                        tone="danger"
                        data-testid="oauth-disconnect-confirm"
                      >
                        <p>
                          Disconnect <span class="font-mono">{connection.client_name}</span>?
                          Its tokens stop working immediately.
                        </p>
                        <div class="flex gap-3 pt-1">
                          <.button
                            type="button"
                            phx-click="disconnect-oauth"
                            phx-value-id={connection.family_id}
                            size="sm"
                            data-testid="oauth-disconnect-confirm-button"
                          >
                            Disconnect app
                          </.button>
                          <.button
                            type="button"
                            phx-click="cancel-oauth-disconnect"
                            variant="ghost"
                            size="sm"
                            data-testid="oauth-disconnect-cancel"
                          >
                            Cancel
                          </.button>
                        </div>
                      </.callout>
                    </li>
                  </ul>
                </div>
              </div>

              <%!-- #483: the actor's own PATs — the MintPat docstring's
                anticipated consumer. The raw value renders ONLY in the
                reveal callout below: minted once, copied or lost, the
                row keeps the hash. Section id is an anchor target like
                #device-sign-ins. --%>
              <div class="space-y-3" id="api-tokens" data-testid="api-tokens">
                <div>
                  <h3 class="text-sm font-medium text-ink-muted">API tokens</h3>
                  <p class="mt-1 text-sm text-ink-muted">
                    Personal access tokens for the machine API. Automation you run, like CI or
                    the CLI, calls the API with one. A token keeps working until it expires or
                    you revoke it.
                  </p>
                </div>

                <.callout
                  :if={@fresh_token}
                  id="api-token-reveal"
                  tone="warning"
                  data-testid="api-token-reveal"
                >
                  <p class="font-medium text-ink" data-testid="api-token-reveal-title">
                    {@fresh_token.name} created. Copy it now.
                  </p>
                  <p>
                    This is the only time the full token is shown. It can't be retrieved again,
                    and anyone holding it can call the API as you, within its scopes.
                  </p>
                  <div class="flex flex-wrap items-center gap-2 pt-1">
                    <code
                      class="max-w-full overflow-x-auto rounded-control border border-line bg-panel px-2 py-1 font-mono text-xs text-ink"
                      data-testid="api-token-reveal-value"
                    >
                      {@fresh_token.token}
                    </code>
                    <.copy_button
                      id={"copy-api-token-#{@fresh_token.id}"}
                      value={@fresh_token.token}
                      label="Copy"
                      testid="api-token-reveal-copy"
                    />
                    <.button
                      type="button"
                      phx-click="dismiss-token-reveal"
                      variant="ghost"
                      size="sm"
                      data-testid="api-token-reveal-done"
                    >
                      Done
                    </.button>
                  </div>
                </.callout>

                <.card id="api-tokens-create-card" class="card space-y-4">
                  <div>
                    <h3 class="text-sm font-medium text-ink-muted">Create a token</h3>
                    <p class="mt-1 text-sm text-ink-muted">
                      Name it for where you'll use it, then pick its scopes.
                    </p>
                  </div>

                  <.form
                    for={@token_form}
                    id={"api-token-form-#{@token_form_key}"}
                    phx-submit="create-token"
                    phx-change="scope-change"
                  >
                    <div class="space-y-4">
                      <.input
                        field={@token_form[:name]}
                        type="text"
                        label="Name"
                        maxlength={100}
                        required
                        placeholder="ci deploys"
                        data-testid="api-token-name-input"
                      />

                      <%!-- The grouped picker (#892): one three-state row
                        per domain (No access / Read / Write), two-state
                        where the catalog has no write scope. The change
                        events keep @scope_levels valid server-side, so
                        the detail blocks, the summary and the mint all
                        read the same expansion. --%>
                      <div>
                        <p class="text-sm font-medium text-ink">Scopes</p>

                        <div
                          data-testid="api-token-scope-groups"
                          class="mt-2 divide-y divide-line rounded-control border border-line bg-panel"
                        >
                          <fieldset
                            :for={domain <- @scope_domains}
                            data-testid={"api-token-scope-group-#{domain.key}"}
                            data-domain={domain.key}
                            data-level={Map.get(@scope_levels, domain.key, "none")}
                            class="p-3"
                          >
                            <legend class="sr-only">{domain.label} access</legend>
                            <% level = Map.get(@scope_levels, domain.key, "none") %>

                            <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
                              <div class="flex items-center gap-2">
                                <span class="text-sm font-medium text-ink">{domain.label}</span>
                                <span
                                  :if={not domain.writable?}
                                  class="rounded-pill border border-line bg-panel-raised px-2 py-0.5 text-xs text-ink-muted"
                                  data-testid={"api-token-scope-readonly-#{domain.key}"}
                                >
                                  Read-only
                                </span>
                              </div>

                              <div class="sm:w-64 sm:shrink-0">
                                <div class={segment_grid_classes(domain)}>
                                  <label
                                    for={"api-token-scope-#{domain.key}-none"}
                                    class={[
                                      "flex cursor-pointer items-center justify-center rounded-control border border-line bg-panel px-1 py-1.5 text-xs font-medium text-ink-muted transition-colors hover:border-line-strong hover:text-ink",
                                      "has-checked:border-line-primary has-checked:bg-primary-muted has-checked:text-ink"
                                    ]}
                                    data-testid={"api-token-scope-#{domain.key}-none"}
                                  >
                                    <input
                                      id={"api-token-scope-#{domain.key}-none"}
                                      type="radio"
                                      name={"token[domain_levels][#{domain.key}]"}
                                      value="none"
                                      checked={level == "none"}
                                      class="sr-only"
                                    /> No access
                                  </label>

                                  <label
                                    for={"api-token-scope-#{domain.key}-read"}
                                    class={[
                                      "flex cursor-pointer items-center justify-center rounded-control border border-line bg-panel px-1 py-1.5 text-xs font-medium text-ink-muted transition-colors hover:border-line-strong hover:text-ink",
                                      "has-checked:border-line-primary has-checked:bg-primary-muted has-checked:text-ink",
                                      level == "write" &&
                                        "border-line-warning bg-warning-muted text-ink"
                                    ]}
                                    data-included={if(level == "write", do: "true", else: "false")}
                                    data-testid={"api-token-scope-#{domain.key}-read"}
                                  >
                                    <input
                                      id={"api-token-scope-#{domain.key}-read"}
                                      type="radio"
                                      name={"token[domain_levels][#{domain.key}]"}
                                      value="read"
                                      checked={level == "read"}
                                      class="sr-only"
                                    />
                                    {if(level == "write", do: "✓ Read", else: "Read")}
                                  </label>

                                  <label
                                    :if={domain.writable?}
                                    for={"api-token-scope-#{domain.key}-write"}
                                    class={[
                                      "flex cursor-pointer items-center justify-center rounded-control border border-line bg-panel px-1 py-1.5 text-xs font-medium text-ink-muted transition-colors hover:border-line-strong hover:text-ink",
                                      "has-checked:border-line-primary has-checked:bg-primary-muted has-checked:text-ink"
                                    ]}
                                    data-testid={"api-token-scope-#{domain.key}-write"}
                                  >
                                    <input
                                      id={"api-token-scope-#{domain.key}-write"}
                                      type="radio"
                                      name={"token[domain_levels][#{domain.key}]"}
                                      value="write"
                                      checked={level == "write"}
                                      class="sr-only"
                                    /> Write
                                  </label>
                                </div>
                              </div>
                            </div>

                            <div
                              data-testid={"api-token-scope-detail-#{domain.key}"}
                              class="mt-2 text-xs text-ink-muted"
                            >
                              <%= case level do %>
                                <% "none" -> %>
                                  <%= if domain.writable? do %>
                                    No access
                                  <% else %>
                                    No access. No write scope exists for this domain.
                                  <% end %>
                                <% "read" -> %>
                                  <span class="font-mono text-ink">{domain.read_scope}</span>
                                  <span>{domain.read_description}</span>
                                <% "write" -> %>
                                  <span class="flex flex-wrap items-center gap-1.5">
                                    <span aria-hidden="true" class="text-ink">✓</span>
                                    <span class="rounded-control bg-panel-raised px-1.5 py-0.5 font-mono text-ink">
                                      {domain.read_scope}
                                    </span>
                                    <span>(included)</span>
                                    <span>{domain.read_description}</span>
                                  </span>
                                  <span class="mt-1 flex flex-wrap items-center gap-1.5">
                                    <span aria-hidden="true" class="text-ink">✓</span>
                                    <span class="rounded-control bg-panel-raised px-1.5 py-0.5 font-mono text-ink">
                                      {domain.write_scope}
                                    </span>
                                    <span>{domain.write_description}</span>
                                  </span>
                              <% end %>
                            </div>
                          </fieldset>
                        </div>

                        <div
                          data-testid="api-token-scope-summary"
                          class="mt-3 rounded-control border border-line bg-panel-raised px-3 py-2 text-xs text-ink-muted"
                        >
                          <% scopes = selected_scopes(@scope_levels) %>
                          <%= if scopes == [] do %>
                            <p>
                              No scopes selected. Leave everything at No access for a token
                              that can only identify itself.
                            </p>
                          <% else %>
                            <p class="text-ink">
                              Minted scopes ({length(scopes)}):
                            </p>
                            <ul class="mt-1.5 flex flex-wrap gap-1">
                              <li
                                :for={scope <- scopes}
                                class="rounded-control bg-panel px-1.5 py-0.5 font-mono text-ink"
                              >
                                {scope}
                              </li>
                            </ul>
                          <% end %>
                        </div>
                      </div>

                      <div class="flex justify-end">
                        <%!-- phx-disable-with closes the in-flight double
                          submit: the re-key disarms re-clicks AFTER the
                          patch, the disabled button closes the window
                          DURING the round trip. --%>
                        <.button
                          type="submit"
                          phx-disable-with="Creating token..."
                          data-testid="api-token-create"
                        >
                          Create token
                        </.button>
                      </div>
                    </div>
                  </.form>
                </.card>

                <%!-- The rows are the token metadata's technical reality in
                  the sunken mono register (the attached apps' posture):
                  the friendly lines carry the sans register. --%>
                <div class="mono-panel min-w-0">
                  <p
                    :if={@api_tokens_empty?}
                    class="font-sans text-sm text-ink-muted"
                    data-testid="api-tokens-empty"
                  >
                    No tokens yet. Create one above.
                  </p>

                  <ul id="api-token-rows" phx-update="stream" class="divide-y divide-line">
                    <li
                      :for={{dom_id, token} <- @streams.api_tokens}
                      id={dom_id}
                      class="space-y-1.5 py-3 first:pt-0 last:pb-0"
                      data-testid="api-token-row"
                    >
                      <div class="flex flex-wrap items-center justify-between gap-3">
                        <div class="flex min-w-0 flex-wrap items-center gap-2">
                          <span
                            class="font-mono text-sm font-medium text-ink"
                            data-testid="api-token-name"
                          >
                            {token.name}
                          </span>
                          <.badge
                            :if={token_status(token) == :active}
                            tone="success"
                            data-testid="api-token-status-active"
                          >
                            <span class="sr-only">Status </span>Active
                          </.badge>
                          <.badge
                            :if={token_status(token) == :revoked}
                            tone="danger"
                            data-testid="api-token-status-revoked"
                          >
                            <span class="sr-only">Status </span>Revoked
                          </.badge>
                          <.badge
                            :if={token_status(token) == :expired}
                            tone="warning"
                            data-testid="api-token-status-expired"
                          >
                            <span class="sr-only">Status </span>Expired
                          </.badge>
                        </div>

                        <.button
                          :if={token_status(token) == :active and @token_revoke_armed_id != token.id}
                          type="button"
                          phx-click="arm-token-revoke"
                          phx-value-id={token.id}
                          variant="ghost"
                          size="sm"
                          data-testid="api-token-revoke"
                        >
                          Revoke
                        </.button>
                      </div>

                      <p class="font-sans text-xs text-ink-muted" data-testid="api-token-meta">
                        <span class="font-mono">{scopes_line(token)}</span>
                        · Created {Calendar.strftime(token.created_at, "%b %d, %Y")} · {last_used_line(
                          token
                        )} · Expires {Calendar.strftime(token.expires_at, "%b %d, %Y")}
                      </p>

                      <p
                        :if={device_minted?(token)}
                        class="font-sans text-xs text-ink-muted"
                        data-testid="api-token-provenance"
                      >
                        Minted by the FluxVale CLI device sign-in.
                      </p>

                      <.callout
                        :if={@token_revoke_armed_id == token.id and token_status(token) == :active}
                        id={"api-token-revoke-confirm-#{token.id}"}
                        tone="danger"
                        data-testid="api-token-revoke-confirm"
                      >
                        <p>
                          Revoke <span class="font-mono">{token.name}</span>? Anything using it
                          stops working now.
                        </p>
                        <div class="flex gap-3 pt-1">
                          <.button
                            type="button"
                            phx-click="revoke-token"
                            phx-value-id={token.id}
                            size="sm"
                            data-testid="api-token-revoke-confirm-button"
                          >
                            Revoke token
                          </.button>
                          <.button
                            type="button"
                            phx-click="cancel-token-revoke"
                            variant="ghost"
                            size="sm"
                            data-testid="api-token-revoke-cancel"
                          >
                            Cancel
                          </.button>
                        </div>
                      </.callout>
                    </li>
                  </ul>
                </div>

                <%!-- #484 W5: the quickstart is ONE click from the mint
                  — a dedicated settings page with the server URL,
                  per-client configs, and the destructive-gate story.
                  The card rode the tokens section here from
                  /settings/access (#638): wherever the mint lives, the
                  recipe links from it. --%>
                <.link
                  navigate={~p"/settings/agents"}
                  class={[
                    "flex items-center justify-between gap-3 rounded-control border border-line bg-panel px-4 py-3",
                    "text-sm text-ink transition-colors hover:border-line-strong hover:bg-panel-raised"
                  ]}
                  data-testid="api-tokens-agents-link"
                >
                  <span class="min-w-0">
                    <span class="font-medium">Use FluxVale with an AI agent.</span>
                    <span class="text-ink-muted">
                      Claude, Cursor, and opencode connect over MCP with a token minted
                      here.
                    </span>
                  </span>
                  <span class="shrink-0 text-ink-muted" aria-hidden="true">&rarr;</span>
                </.link>
              </div>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
