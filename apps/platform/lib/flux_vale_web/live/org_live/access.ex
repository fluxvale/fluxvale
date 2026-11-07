defmodule FluxValeWeb.OrganizationLive.Access do
  @moduledoc """
  Org settings, Access tab (#273, ADR-0039): the private-access
  gateway's owner surface — enable, watch, re-paste the key, resume
  after suspension, remove, and pair instances (attach/detach, §4.1 —
  the owner's reachability switch).

  Slug-keyed mount like the sibling tabs; unknown slugs (and policy
  denials) read as "not here" — never a bare 404. Owners-only in the
  panel is a UX gate, not the authority: the actions' own policies
  (membership, funded wallet) are what actually forbid a call. The
  wallet hints report the wallet each affordance acts on — enable bills
  the page org (#408: the create names it), resume the row's org.

  S5: the personal org's access panel moved INTO user settings —
  `/settings/access` mounts this same LiveView under the named
  `:personal` action and serves the actor's personal org, so the
  slug-keyed route for a personal slug redirects there. The two heads
  are kept apart by the route's action: a `?slug=` query param on the
  personal route is refused as not-found (LiveView merges query params
  into mount params — without the named head it would mount the org
  frame on the personal page). The org chrome (header, tabs) renders
  for real orgs only; the personal page carries the user-settings
  frame.

  Live updates ride the gateway's per-org PubSub topic — every state
  write publishes there (the observer's minute tick, the ladder's
  suspension, a resume from another tab), and the teardown's hard
  delete refetches the panel to the empty state. The auth key is
  write-only: a password input, and no read-back path ever returns the
  stored key (ADR-0039 §4).

  API tokens (#483): the actor's own PATs — create (name + scopes off
  the existing catalog), the raw value shown once at creation, and
  revoke, effective immediately. Self-service by construction: the
  reads and writes ride the owner-scoped policies, the same list
  either head serves (the device sign-ins' posture).
  """

  use FluxValeWeb, :live_view

  alias Ash.Error.Forbidden
  alias FluxVale.Accounts.Organization
  alias FluxVale.Api.Scopes
  alias FluxVale.Checks.ActorIsOrganizationOwner
  alias FluxVale.Checks.ActorOrgHasPaid
  alias FluxVale.Checks.ActorOrgWalletFunded
  alias FluxVale.Identity
  alias FluxVale.Identity.DeviceCode
  alias FluxVale.Identity.PersonalAccessToken
  alias FluxVale.Infrastructure
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessRoute
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Pricing
  alias FluxValeWeb.AccountSettings
  alias FluxValeWeb.OrgSettings
  alias FluxValeWeb.PersonalOrg

  @impl Phoenix.LiveView
  # The :personal route's contract is NO slug — but LiveView merges query
  # params into mount params, so `/settings/access?slug=…` lands in mount
  # with one and would take the slug-keyed head below, mounting the org
  # frame (header, tabs, the URL org's gateway and its PubSub topic) on
  # the personal route — a page whose enable form would name the URL org
  # while the frame shows the personal one, and that the created row's
  # own topic can never update. So on this route the param is refused
  # outright: not-found, the codebase's posture for a hand-typed path.
  # (First clause: it must win over the slug-keyed head for this action.)
  def mount(%{"slug" => _refused}, _session, %{assigns: %{live_action: :personal}} = socket) do
    {:ok,
     socket
     |> put_flash(:error, "Organization not found.")
     |> push_navigate(to: ~p"/")}
  end

  def mount(%{"slug" => slug}, _session, socket) do
    user = socket.assigns.current_user

    case Organization.get_by_slug(slug, actor: user) do
      {:ok, org} ->
        cond do
          # S5: the personal org never renders an org page — its access
          # panel lives at /settings/access, served below by this same
          # module without a slug. Flash-free (nothing failed).
          PersonalOrg.personal?(socket, org) ->
            {:ok, push_navigate(socket, to: ~p"/settings/access")}

          # UX gate, not the authority: the actions' own policies (member
          # read, funded-wallet create/resume) are what actually forbid a
          # non-owner call. This only spares a member a settings surface
          # that is owners-only by design — same posture as Settings.
          ActorIsOrganizationOwner.owner?(user, org) ->
            {:ok, mount_panel(socket, org, user)}

          true ->
            {:ok,
             socket
             |> put_flash(:error, "Only organization owners can access settings.")
             |> push_navigate(to: ~p"/")}
        end

      _error ->
        {:ok,
         socket
         |> put_flash(:error, "Organization not found.")
         |> push_navigate(to: ~p"/")}
    end
  end

  # /settings/access (:personal, S5): the personal account's access
  # panel. The org is the actor's personal org through the canonical
  # resolver — its :owner-membership filter IS the owner gate here, so
  # no separate check. No slug in the contract, nothing to enumerate.
  def mount(_params, _session, %{assigns: %{live_action: :personal}} = socket) do
    user = socket.assigns.current_user

    case PersonalOrg.org_for(user) do
      {:ok, org} ->
        {:ok, mount_panel(socket, org, user)}

      # Seeded/legacy no-personal-org shape (OrgNav's stance) — the
      # surface isn't here; the sibling not-found arm's answer.
      :none ->
        {:ok,
         socket
         |> put_flash(:error, "Organization not found.")
         |> push_navigate(to: ~p"/")}

      # defensive: DB read failure, not simulatable under the
      # sandbox. Same degrade as the slug arm's miss.
      # coveralls-ignore-start
      {:error, _reason} ->
        {:ok,
         socket
         |> put_flash(:error, "Organization not found.")
         |> push_navigate(to: ~p"/")}

        # coveralls-ignore-stop
    end
  end

  # The panel setup both routes share — one gateway per org, whatever
  # resolved it (URL slug or the actor's personal org). The route's own
  # action picks the chrome: the org frame (header, tabs, org billing
  # links) for the slug route, the user-settings frame for :personal.
  defp mount_panel(%{assigns: %{live_action: :personal}} = socket, org, user) do
    mount_panel_for(socket, org, user, true)
  end

  defp mount_panel(socket, org, user) do
    mount_panel_for(socket, org, user, false)
  end

  defp mount_panel_for(socket, org, user, personal?) do
    # The per-org topic, never a global one: every gateway write
    # broadcasts here, so only this org's open panels refetch.
    Phoenix.PubSub.subscribe(FluxVale.PubSub, "access_gateways:#{org.id}")

    gateway = fetch_gateway(org, user)

    socket
    |> assign(
      org: org,
      personal?: personal?,
      current_org: if(personal?, do: nil, else: org),
      billing_path: billing_path(org, personal?),
      gateway: gateway,
      price_cents: monthly_cents()
    )
    |> assign(repaste_open?: repaste_open_for(gateway), remove_armed?: false)
    |> assign(attach_error: nil)
    |> stream_configure(:attached, dom_id: &"access-attached-#{&1.route.id}")
    |> stream_configure(:attachable, dom_id: &"access-attach-#{&1.id}")
    |> stream_configure(:device_sign_ins, dom_id: &"device-sign-in-#{&1.id}")
    |> stream_configure(:api_tokens, dom_id: &"api-token-#{&1.id}")
    |> refresh_wallet_gates()
    |> assign_forms()
    |> assign(fresh_token: nil, token_revoke_armed_id: nil, token_form_key: 0)
    |> assign(token_form: to_form(%{"name" => ""}, as: "token", id: "api-token-form-0"))
    |> assign(catalog_scopes: Scopes.all_scopes())
    |> refresh_pairing()
    |> refresh_device_sign_ins()
    |> refresh_api_tokens()
  end

  # The top-up links inside the panel: a real org bills at its org URL,
  # the personal org at /billing (S5 — one wallet, one surface).
  defp billing_path(_org, true), do: ~p"/billing"
  defp billing_path(org, false), do: ~p"/organizations/#{org.slug}/billing"

  @impl Phoenix.LiveView
  def handle_event("validate", %{"gateway" => params}, socket) do
    form =
      socket.assigns.form
      |> AshPhoenix.Form.validate(form_params(params, socket))
      |> clear_key_display()

    {:noreply, assign(socket, form: form)}
  end

  # Enable — the empty state's create. The panel owns the two create
  # inputs the form doesn't render: the org, and the price snapshot the
  # row keeps (the price the owner opted in at is the price they keep).
  def handle_event("enable", %{"gateway" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.form, params: form_params(params, socket)) do
      {:ok, gateway} ->
        {:noreply,
         socket
         |> put_flash(:info, "Private access is connecting. This page updates on its own.")
         |> assign(gateway: gateway)
         |> assign(repaste_open?: repaste_open_for(gateway), remove_armed?: false)
         |> assign_forms()}

      {:error, form} ->
        if forbidden?(form) do
          # A policy gate (funded or paid-once) — the fix is the wallet,
          # so the copy says so instead of rendering a field error. The
          # form is rebuilt from the row (no key echo — see
          # clear_key_display) and carries only the errors.
          {:noreply,
           socket
           |> put_flash(:error, "Top up before enabling private access.")
           |> rebuild_form_with_errors(form)}
        else
          {:noreply,
           socket
           |> put_flash(:error, "Couldn't enable private access. Try again.")
           |> rebuild_form_with_errors(form)}
        end
    end
  end

  # Re-paste — the NeedsLogin / deleted-node recovery. The engine writes
  # the Secret and restarts; the copy stays "reconnect", never the
  # machinery underneath.
  def handle_event("repaste", %{"gateway" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.form, params: params) do
      {:ok, gateway} ->
        {:noreply,
         socket
         |> put_flash(:info, "Reconnecting with the new key. This page updates on its own.")
         |> assign(gateway: gateway)
         |> assign(repaste_open?: repaste_open_for(gateway))
         |> assign_forms()}

      {:error, form} ->
        # The engine's own answer (the change writes "Couldn't update
        # the access key — try again") is field-less, so the flash is
        # its surface — never a silent dead click. The form rebuilds
        # from the row carrying only the errors: the submitted key is
        # not echoed back (ADR-0039 §4).
        {:noreply,
         socket
         |> put_flash(:error, "Couldn't update the access key. Try again.")
         |> rebuild_form_with_errors(form)}
    end
  end

  def handle_event("toggle-repaste", _params, socket) do
    {:noreply, assign(socket, repaste_open?: not socket.assigns.repaste_open?)}
  end

  # The empty state is a normal state of this panel (the teardown can
  # delete the row out from under any card), so every event in the
  # remove family is a no-op there — a nil gateway has nothing to arm,
  # remove, or retry, and a real double-click on Retry removal lands
  # exactly here after the first click's teardown wins.
  def handle_event("arm-remove", _params, %{assigns: %{gateway: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("arm-remove", _params, socket) do
    {:noreply, assign(socket, remove_armed?: true)}
  end

  def handle_event("retry-remove", _params, %{assigns: %{gateway: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("cancel-remove", _params, socket) do
    {:noreply, assign(socket, remove_armed?: false)}
  end

  # Guarded: only an armed panel removes — every path here passes
  # through the explicit confirm callout first (Settings' armed-rename
  # posture), so a crafted click cannot delete on its own. The nil
  # gateway arm is the empty state (see the arm-remove guard).
  def handle_event("remove", _params, %{assigns: %{gateway: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("remove", _params, socket) do
    case socket.assigns do
      %{remove_armed?: true} ->
        case Infrastructure.delete_access_gateway(socket.assigns.gateway.id,
               actor: socket.assigns.current_user
             ) do
          {:ok, gateway} ->
            {:noreply,
             socket
             |> put_flash(:info, "Removing private access. Billing stops now.")
             |> assign(gateway: gateway)
             |> assign(remove_armed?: false)
             |> assign_forms()}

          {:error, _reason} ->
            # The stale-view arm: the row vanished (teardown won the
            # race) — the next broadcast lands the empty state.
            {:noreply, put_flash(socket, :error, "Could not remove private access. Try again.")}
        end

      _unarmed ->
        {:noreply, socket}
    end
  end

  # A failed removal parks the row in :destroying — this is its owner
  # path forward. The engine's delete re-enqueues idempotently from
  # :destroying (its own comment: a duplicate against a live job costs
  # one wasted pass), so one explicit click needs no confirm arm; the
  # destructive confirm stays on the :active/:needs_attention/:suspended
  # cards, where the click is what STARTS the removal.
  def handle_event("retry-remove", _params, socket) do
    case Infrastructure.delete_access_gateway(socket.assigns.gateway.id,
           actor: socket.assigns.current_user
         ) do
      {:ok, gateway} ->
        {:noreply,
         socket
         |> put_flash(:info, "Retrying removal. This page updates on its own.")
         |> assign(gateway: gateway)
         |> assign(remove_armed?: false)
         |> assign_forms()}

      {:error, _reason} ->
        # The stale-view arm: the row vanished (the in-flight teardown
        # won) — the next broadcast lands the empty state.
        {:noreply, put_flash(socket, :error, "Could not remove private access. Try again.")}
    end
  end

  # The zero-balance ladder's undo — the engine's funded-wallet policy
  # is the authority; the flash just says what the wallet needs.
  def handle_event("resume", _params, socket) do
    case AccessGateway.resume(socket.assigns.gateway, actor: socket.assigns.current_user) do
      {:ok, gateway} ->
        {:noreply,
         socket
         |> put_flash(:info, "Private access is reconnecting. This page updates on its own.")
         |> assign(gateway: gateway)
         |> refresh_wallet_gates()
         |> assign_forms()}

      {:error, %Forbidden{}} ->
        {:noreply, put_flash(socket, :error, "Top up before resuming private access.")}

      {:error, error} ->
        if stale_gateway?(error) do
          # The stale-view arm: another tab won the resume (or the
          # teardown won the race) between this panel's last refetch and
          # the click. The row filter refused the write — retrying here
          # would guess at a state this panel cannot see. Settings'
          # stale posture: reload, not retry.
          {:noreply,
           put_flash(socket, :error, "This gateway changed underneath you. Reload to continue.")}
        else
          # A transient failure mid-resume (the scale call) — the row
          # kept :suspended, so the retry is the same button.
          {:noreply, put_flash(socket, :error, "Could not resume private access. Try again.")}
        end
    end
  end

  # ---- Pairing (ADR-0039 §3): the owner's reachability switch ----

  # The sections aren't rendered without a gateway (or on a gateway the
  # operation would refuse), so these guards are the crafted/stale-click
  # arms — no-ops, never crashes (the remove family's stance). The
  # trailing catch-alls make that total over crafted payloads too: a
  # phx event without an instance_id is a no-op, not a crash.
  def handle_event("attach", _params, %{assigns: %{gateway: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("attach", %{"instance_id" => instance_id}, socket) do
    user = socket.assigns.current_user

    case Instance.get_by_id(instance_id, actor: user) do
      {:ok, instance} ->
        attach(socket, instance)

      # The stale view: the instance left between this panel's render
      # and the click — the generic copy is the honest answer to a
      # click that can no longer mean anything.
      _gone ->
        # The instance left between render and click — a stale row. The
        # generic copy answers the click AND the lists re-read so the
        # ghost row disappears instead of failing forever.
        {:noreply,
         socket
         |> assign(attach_error: :cluster)
         |> refresh_pairing()}
    end
  end

  def handle_event("attach", _params, socket), do: {:noreply, socket}

  def handle_event("detach", _params, %{assigns: %{gateway: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("detach", %{"instance_id" => instance_id}, socket) do
    user = socket.assigns.current_user

    case Instance.get_by_id(instance_id, actor: user) do
      {:ok, instance} ->
        case Infrastructure.detach_instance(socket.assigns.gateway, instance) do
          :ok ->
            {:noreply,
             socket
             |> put_flash(:info, detach_flash(instance))
             |> refresh_pairing()}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Couldn't detach. Try again.")}
        end

      _gone ->
        # Stale row (CodeRabbit round): refresh alongside the retry copy
        # so a vanished instance leaves the attached list, not a ghost
        # that re-fails every click.
        {:noreply,
         socket
         |> put_flash(:error, "Couldn't detach. Try again.")
         |> refresh_pairing()}
    end
  end

  def handle_event("detach", _params, socket), do: {:noreply, socket}

  # ---- Device sign-ins (#362 T3): approve / deny the device flow ----

  # Approve binds the row to the CLICKING user (the :approve action's
  # contract — the argument rides the actor, never form params), and
  # the CLI's next poll mints the PAT for them. The stale arms (the
  # row was approved/denied elsewhere, or expired, between render and
  # click) find nothing pending and converge through the refetch —
  # the remove family's no-op posture.
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

  # ---- API tokens (#483): create, list, revoke the actor's own PATs ----

  # The create rides the MintPat operation (the domain is the seam):
  # scopes validated against the catalog twice (operation + resource),
  # the hash-only write, the raw value back exactly once. The form
  # offers exactly the catalog, so an off-catalog scope can only
  # arrive crafted — the domain still refuses it before anything is
  # generated. Empty scopes is a valid mint (the scopeless routes).
  def handle_event("create-token", %{"token" => params}, socket) when is_map(params) do
    user = socket.assigns.current_user
    name = name_from(params)

    scopes = List.wrap(params["scopes"] || [])

    if name == "" do
      {:noreply, put_flash(socket, :error, "Give the token a name first.")}
    else
      case Identity.mint_pat(user, %{user_id: user.id, name: name, scopes: scopes}) do
        {:ok, %{token: raw, pat: pat}} ->
          {:noreply,
           socket
           |> assign(fresh_token: %{id: pat.id, name: pat.name, token: raw})
           |> assign_new_form_key()
           |> refresh_api_tokens()}

        {:error, {kind, _scope}} when kind in [:invalid_scope, :duplicate_scope] ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "Couldn't create the token. The scope selection wasn't valid. Refresh and try again."
           )}

        {:error, _refused} ->
          {:noreply,
           put_flash(socket, :error, "Couldn't create the token. Check the name and try again.")}
      end
    end
  end

  # A crafted submit without the form payload is a no-op (the attach
  # family's posture), never a crash — wrong-typed payloads included:
  # a non-map token or a non-binary name lands in the empty-name
  # refusal, never an exception.
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
        # refetch, the remove family's stale posture.
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

  # The actor's pending sign-in requests — the same list on the org
  # and personal panels (rows are unattributed until an approval
  # binds one to the clicking user; the human compares the on-screen
  # user_code with their terminal's before clicking, the gh posture).
  defp refresh_device_sign_ins(socket) do
    pending = DeviceCode.pending!(actor: socket.assigns.current_user)

    socket
    |> stream(:device_sign_ins, pending, reset: true)
    |> assign(device_sign_ins_empty?: pending == [])
  end

  # The actor's own rows, newest first — DateTime.compare/2 is the
  # chronological comparison (term ordering on the structs orders map
  # keys alphabetically, microsecond before second, and would scramble
  # anything within the same minute). The id breaks same-instant ties.
  # The read policy scopes to the owner (user_id == actor.id) and the
  # filter argument names the same user, so the bang cannot meet a
  # refusal (the pairing lists' stance).
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
  # (HTML default-value semantics) — the checkboxes are likewise
  # uncontrolled — so a plain re-assign would leave the submission
  # armed for a duplicate mint on the next click. A changed id replaces
  # the whole form subtree: fresh inputs, server-rendered defaults. A
  # FAILED submit keeps the key, so the user fixes the name instead of
  # retyping it.
  defp assign_new_form_key(socket) do
    key = socket.assigns.token_form_key + 1

    socket
    |> assign(token_form_key: key)
    |> assign(token_form: to_form(%{"name" => ""}, as: "token", id: "api-token-form-#{key}"))
  end

  defp name_from(%{"name" => name}) when is_binary(name), do: String.trim(name)
  defp name_from(_params), do: ""

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

  # The human hint beside each catalog scope string, built from the
  # string itself so a catalog addition labels itself (the checkboxes
  # render from Scopes.all_scopes/0, so the two can't drift apart).
  defp scope_label(scope) do
    case String.split(scope, ":") do
      [domain, "read"] -> String.capitalize(domain) <> ", read only"
      [domain, _write] -> String.capitalize(domain) <> ", manage (includes read)"
      # A multi-colon catalog scope cannot exist while Scopes.validate
      # is exact-membership; the arm bounds a future shape (the raw
      # string labels itself) instead of crashing every mount.
      # coveralls-ignore-next-line
      _other -> scope
    end
  end

  @impl Phoenix.LiveView
  # The per-org topic's catch-all: every gateway write lands here (the
  # observer's tick, a state change from another tab, the create) and so
  # does the teardown's hard delete — a read miss IS the delete, and
  # refetching to the nil state is the honest answer (empty state, form
  # rebuilt). The DB is the one ordering that can't lie: notification
  # data can trail fresher writes, so never trust it — refetch (the
  # Instance panel's stance).
  def handle_info(%Ash.Notifier.Notification{}, socket) do
    previous = state_of(socket.assigns.gateway)
    gateway = fetch_gateway(socket.assigns.org, socket.assigns.current_user)

    socket =
      socket
      |> assign(:gateway, gateway)
      |> refresh_wallet_gates()
      |> maybe_rebuild_panel(gateway, previous)

    {:noreply, socket}
  end

  # Rebuild the panel's chrome only when the state actually moved — a
  # no-op broadcast (the observer re-publishing the same state) must not
  # wipe a half-typed key out of the re-paste form. A state move can
  # also flip the pairing sections' visibility (the suspension hides
  # them), so their data refetches with the chrome.
  defp maybe_rebuild_panel(socket, gateway, previous) do
    if state_of(gateway) == previous do
      socket
    else
      socket
      |> assign(repaste_open?: repaste_open_for(gateway), remove_armed?: false)
      |> assign_forms()
      |> refresh_pairing()
    end
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
      current_org={@current_org}
      bare
    >
      <%!-- App-wide grammar page (S10): `bare` main + .appgram — the
      page owns ALL of main's rhythm. This is the mono-panel grammar's
      dense home: the gateway's technical reality (hostname, rate, the
      pairing rows) in the sunken mono register, the ACTIONS on raised
      cards — the instance-show pattern, asymmetric. --%>
      <div class="appgram contents">
        <%= if @personal? do %>
          <%!-- S5: the personal account's frame — the account band and
          the way back. No org chrome here: the personal org is the
          account, never presented as an org. --%>
          <section class="band">
            <div class="wrap pt-8 pb-10">
              <div class="rise">
                <.link
                  navigate={~p"/settings"}
                  data-testid="settings-access-back"
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
        <% else %>
          <OrgSettings.org_header org={@org} surface="Access" />
        <% end %>

        <section class="wrap pt-8 pb-16">
          <div class="rise flex flex-col gap-8 md:flex-row md:gap-12">
            <%!-- #551: the account cluster's section sidebar rides the
            personal head only — the org head keeps the org rail below. --%>
            <AccountSettings.sidebar
              :if={@personal?}
              current="access"
              personal_org_id={@personal_org_id}
            />

            <div class="min-w-0 flex-1 space-y-6">
              <OrgSettings.settings_tabs :if={!@personal?} current="access" slug={@org.slug} />

              <div>
                <h2 class="text-base font-medium text-ink">Access</h2>
                <p class="mt-1 text-sm text-ink-muted">
                  Reach your private apps from your own Tailscale network.
                </p>
              </div>

              <%= if @gateway do %>
                <.gateway_card
                  gateway={@gateway}
                  form={@form}
                  row_funded?={@row_funded?}
                  row_paid?={@row_paid?}
                  billing_path={@billing_path}
                  repaste_open?={@repaste_open?}
                  remove_armed?={@remove_armed?}
                />

                <%!-- §4.1's pairing sections — only while the operation would
                  accept an attach; every other state gets one honest line
                  instead (the banner explains why). --%>
                <p
                  :if={pairing_paused_copy(@gateway)}
                  class="text-sm text-ink-muted"
                  data-testid="access-pairing-paused"
                >
                  {pairing_paused_copy(@gateway)}
                </p>

                <.attached_card
                  :if={pairing_open?(@gateway)}
                  gateway={@gateway}
                  attached={@streams.attached}
                  attached_empty?={@attached_empty?}
                />

                <.attach_card
                  :if={pairing_open?(@gateway)}
                  attachable={@streams.attachable}
                  attachable_empty?={@attachable_empty?}
                  attach_error={@attach_error}
                />
              <% else %>
                <.access_empty_state
                  personal?={@personal?}
                  form={@form}
                  create_funded?={@create_funded?}
                  create_paid?={@create_paid?}
                  billing_path={@billing_path}
                  price_cents={@price_cents}
                />
              <% end %>

              <%!-- #362: the device flow's approval surface — the actor's
                pending sign-in requests. The rows are unattributed
                until an approval binds one to the clicking user; the
                copy carries the human check (compare the code with
                your terminal). Section id is the verification_uri
                fragment's target (/settings/access/device lands
                here). --%>
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

                      <div>
                        <p class="text-sm font-medium text-ink">Scopes</p>
                        <ul class="mt-2 space-y-2">
                          <li :for={scope <- @catalog_scopes} class="flex items-center gap-2.5">
                            <input
                              id={"api-token-scope-#{scope}"}
                              type="checkbox"
                              name="token[scopes][]"
                              value={scope}
                              class="size-4 rounded border-line-strong accent-primary"
                              data-testid="api-token-scope"
                            />
                            <label
                              for={"api-token-scope-#{scope}"}
                              class="flex cursor-pointer flex-wrap items-center gap-2 text-sm text-ink"
                            >
                              <span class="font-mono text-xs">{scope}</span>
                              <span class="text-xs text-ink-subtle">{scope_label(scope)}</span>
                            </label>
                          </li>
                        </ul>
                        <p class="mt-2 text-xs text-ink-subtle">
                          Write includes read for its domain. Leave all unchecked for a token
                          that can only identify itself, like the account profile route.
                        </p>
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
              </div>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  # The no-gateway surface: what private access is, the three tailnet
  # prerequisites the panel cannot do for the owner (ADR-0039 §8 — it
  # only names them), the price, and the key intake. `personal?` picks
  # the explainer's noun — the account on the personal frame, the
  # organization on the org frame (S5: the personal org never presents
  # as one, copy included).
  attr(:personal?, :boolean, required: true)
  attr(:billing_path, :string, required: true)
  attr(:form, :any, required: true)
  attr(:create_funded?, :boolean, required: true)
  attr(:create_paid?, :boolean, required: true)
  attr(:price_cents, :integer, required: true)

  defp access_empty_state(assigns) do
    ~H"""
    <div class="max-w-2xl space-y-6" data-testid="access-empty">
      <.card id="access-intro-card" class="card space-y-4">
        <div>
          <h3 class="text-sm font-medium text-ink-muted">Private access</h3>
          <p class="mt-2 text-sm text-ink" data-testid="access-explainer">
            Put your private apps on your own Tailscale network, reachable from your own
            devices, never the public internet.
            <%= if @personal? do %>
              One gateway serves every app in your organization and each app gets its own
              address on it.
            <% else %>
              One gateway serves the whole organization and each app gets its own address on
              it.
            <% end %>
          </p>
        </div>

        <div data-testid="access-prereqs">
          <p class="text-sm font-medium text-ink">
            Before you start, set up once in your Tailscale admin console:
          </p>
          <ul class="mt-2 list-disc space-y-1 pl-5 text-sm text-ink-muted">
            <li>
              Create a tag for FluxVale (for example <span class="font-mono">tag:fluxvale</span>)
              and make yourself its owner.
            </li>
            <li>Turn on MagicDNS.</li>
            <li>Turn on HTTPS on the DNS page.</li>
          </ul>
        </div>

        <p class="text-sm text-ink" data-testid="access-price">
          <span class="font-mono">{Pricing.format_usd(@price_cents)}</span>/month, billed hourly
          while connected.
        </p>

        <%!-- The blocking gate's own hint, shown up front: a wallet that
            has never PAID sees the paid-once callout (the welcome credit
            does not unlock enablement), a paid-but-empty one the balance
            copy. Two testids — the states assert separately. --%>
        <.callout
          :if={!@create_paid?}
          id="access-paid-hint"
          tone="warning"
          data-testid="access-paid-hint"
        >
          <p>
            Private access needs a one-time top-up of at least $1. Add funds in <.link
              navigate={@billing_path}
              class="underline underline-offset-2 hover:text-ink"
              data-testid="access-paid-link"
            >
              Billing
            </.link>.
          </p>
        </.callout>

        <.callout
          :if={@create_paid? and !@create_funded?}
          id="access-prefund-hint"
          tone="warning"
          data-testid="access-prefund-hint"
        >
          <p>
            Your balance is empty. Top up before enabling private access. Start from <.link
              navigate={@billing_path}
              class="underline underline-offset-2 hover:text-ink"
              data-testid="access-prefund-link"
            >
              Billing
            </.link>.
          </p>
        </.callout>
      </.card>

      <.card id="access-enable-card" class="card space-y-4">
        <div>
          <h3 class="text-sm font-medium text-ink-muted">Enable private access</h3>
          <p class="mt-1 text-sm text-ink-muted">
            Paste a reusable auth key from your Tailscale admin console. It is stored in
            our own secret store and never shown again.
          </p>
        </div>

        <.form for={@form} id="access-enable-form" phx-change="validate" phx-submit="enable">
          <div class="space-y-4">
            <.input
              field={@form[:auth_key]}
              type="password"
              label="Auth key"
              placeholder="tskey-auth-…"
              required
              data-testid="access-key-input"
            />
            <.input
              field={@form[:tailnet_domain]}
              type="text"
              label="Tailnet domain"
              placeholder="your-tailnet.ts.net"
              required
              data-testid="access-domain-input"
            />
            <p class="text-xs text-ink-muted">
              Your tailnet's DNS name, the part after the first dot in any of your
              device names, visible in your Tailscale admin console. It becomes part of
              every private app's address.
            </p>
            <div class="flex justify-end">
              <.button type="submit" data-testid="access-enable">
                Enable private access
              </.button>
            </div>
          </div>
        </.form>
      </.card>
    </div>
    """
  end

  attr(:gateway, AccessGateway, required: true)
  attr(:form, :any, required: true)
  attr(:row_funded?, :boolean, required: true)
  attr(:row_paid?, :boolean, required: true)
  attr(:billing_path, :string, required: true)
  attr(:repaste_open?, :boolean, required: true)
  attr(:remove_armed?, :boolean, required: true)

  defp gateway_card(assigns) do
    ~H"""
    <%!-- The instance-show pattern: the technical reality in the sunken
    mono panel beside the raised actions card, asymmetric (1.4fr/1fr —
    no fake symmetry). The panel carries what the gateway IS (state,
    hostname, rate); the card carries what you DO (re-paste, remove,
    resume) — actions stay form surfaces, never sunken. --%>
    <div class="min-w-0 items-start gap-6 space-y-6 lg:grid lg:grid-cols-[minmax(0,1.4fr)_minmax(0,1fr)] lg:space-y-0">
      <div class="mono-panel min-w-0 space-y-3" data-testid="access-gateway-card">
        <div class="flex items-center gap-2">
          <h3 class="mono-panel-label mb-0">Private access</h3>
          <.status_badge status={@gateway.state} />
        </div>

        <div class="grid gap-1.5">
          <p class="flex gap-4">
            <span class="w-24 shrink-0">hostname:</span>
            <span
              class="min-w-0 text-ink [overflow-wrap:anywhere]"
              data-testid="access-hostname"
            >
              {@gateway.hostname}
            </span>
          </p>
          <p class="flex gap-4">
            <span class="w-24 shrink-0">rate:</span>
            <span class="min-w-0" data-testid="access-billing-line">
              {Pricing.format_usd(@gateway.monthly_cents)}/month, billed hourly while
              connected. Suspended or removed, nothing accrues.
            </span>
          </p>
        </div>
      </div>

      <.card class="card min-w-0 space-y-4">
        <%!-- the engine's own words for the state — written friendly by
        design (the #179 split: technical detail never leaves the row). --%>
        <p
          :if={@gateway.status_message}
          class="text-sm text-ink"
          data-testid="access-status-message"
        >
          {@gateway.status_message}
        </p>

        <.gateway_actions
          gateway={@gateway}
          form={@form}
          row_funded?={@row_funded?}
          row_paid?={@row_paid?}
          billing_path={@billing_path}
          repaste_open?={@repaste_open?}
          remove_armed?={@remove_armed?}
        />
      </.card>
    </div>
    """
  end

  attr(:gateway, AccessGateway, required: true)
  attr(:form, :any, required: true)
  attr(:row_funded?, :boolean, required: true)
  attr(:row_paid?, :boolean, required: true)
  attr(:billing_path, :string, required: true)
  attr(:repaste_open?, :boolean, required: true)
  attr(:remove_armed?, :boolean, required: true)

  defp gateway_actions(assigns) do
    ~H"""
    <div class="space-y-4">
      <%= cond do %>
        <% @gateway.state == :provisioning -> %>
          <p class="text-sm text-ink-muted" data-testid="access-connecting-note">
            Setting up access, usually under a minute. If it sticks, reconnect with
            your key.
          </p>
          <.repaste_panel
            form={@form}
            open?={@repaste_open?}
            toggle_label="Re-paste key"
            submit_label="Save key"
          />
        <% @gateway.state == :active -> %>
          <.repaste_panel
            form={@form}
            open?={@repaste_open?}
            toggle_label="Re-paste key"
            submit_label="Save key"
          />
          <.remove_panel armed?={@remove_armed?} />
        <% @gateway.state == :needs_attention -> %>
          <.callout id="access-attention-note" tone="warning" data-testid="access-attention-note">
            <p>
              We can't reach your gateway. The key may have expired, or the node was
              removed from your Tailscale admin console. Paste a fresh key to reconnect.
            </p>
          </.callout>
          <.repaste_panel
            form={@form}
            open?={@repaste_open?}
            toggle_label="Reconnect"
            submit_label="Reconnect"
            prominent?
          />
          <.remove_panel armed?={@remove_armed?} />
        <% @gateway.state == :suspended -> %>
          <.suspended_panel
            row_funded?={@row_funded?}
            row_paid?={@row_paid?}
            billing_path={@billing_path}
          />
          <.remove_panel armed?={@remove_armed?} />
        <% @gateway.state == :destroying -> %>
          <p class="text-sm text-ink-muted" data-testid="access-removing-note">
            Removing private access… This page updates on its own.
          </p>
          <.button
            type="button"
            phx-click="retry-remove"
            variant="ghost"
            size="sm"
            data-testid="access-retry-remove"
          >
            Retry removal
          </.button>
      <% end %>
    </div>
    """
  end

  attr(:form, :any, required: true)
  attr(:open?, :boolean, required: true)
  attr(:toggle_label, :string, required: true)
  attr(:submit_label, :string, required: true)
  attr(:prominent?, :boolean, default: false)

  defp repaste_panel(assigns) do
    ~H"""
    <div data-testid="access-repaste">
      <%= if @open? do %>
        <.form
          for={@form}
          id="access-repaste-form"
          phx-change="validate"
          phx-submit="repaste"
          class="space-y-3"
        >
          <.input
            field={@form[:auth_key]}
            type="password"
            label="New auth key"
            placeholder="tskey-auth-…"
            required
            data-testid="access-repaste-key"
          />
          <.input
            field={@form[:tailnet_domain]}
            type="text"
            label="Tailnet domain"
            placeholder="your-tailnet.ts.net"
            required
            data-testid="access-repaste-domain"
          />
          <div class="flex gap-3">
            <.button type="submit" size="sm" data-testid="access-repaste-submit">
              {@submit_label}
            </.button>
            <.button
              type="button"
              phx-click="toggle-repaste"
              variant="ghost"
              size="sm"
              data-testid="access-repaste-hide"
            >
              Cancel
            </.button>
          </div>
        </.form>
      <% else %>
        <.button
          type="button"
          phx-click="toggle-repaste"
          variant={if(@prominent?, do: "primary", else: "ghost")}
          size="sm"
          data-testid="access-repaste-toggle"
        >
          {@toggle_label}
        </.button>
      <% end %>
    </div>
    """
  end

  attr(:armed?, :boolean, required: true)

  defp remove_panel(assigns) do
    ~H"""
    <div class="border-t border-line pt-4">
      <%= if @armed? do %>
        <.callout id="access-remove-confirm" tone="danger" data-testid="access-remove-confirm">
          <p>
            Remove private access? Your private apps fall back to panel-only private,
            reachable only inside FluxVale, and billing stops.
          </p>
          <div class="flex gap-3 pt-1">
            <.button type="button" phx-click="remove" size="sm" data-testid="access-confirm-remove">
              Remove private access
            </.button>
            <.button
              type="button"
              phx-click="cancel-remove"
              variant="ghost"
              size="sm"
              data-testid="access-cancel-remove"
            >
              Cancel
            </.button>
          </div>
        </.callout>
      <% else %>
        <.button
          type="button"
          phx-click="arm-remove"
          variant="ghost"
          size="sm"
          data-testid="access-remove"
        >
          Remove
        </.button>
      <% end %>
    </div>
    """
  end

  # The resume button only where resume can succeed — the ROW's org
  # funded AND paid. A never-paid org (funded on welcome credit alone)
  # would hit the paid-once Forbidden, so it sees the top-up line
  # instead.
  attr(:row_funded?, :boolean, required: true)
  attr(:row_paid?, :boolean, required: true)
  attr(:billing_path, :string, required: true)

  defp suspended_panel(assigns) do
    ~H"""
    <div class="space-y-3" data-testid="access-suspended-banner">
      <.callout id="access-suspended-callout" tone="warning">
        <p>
          Private access is suspended. The balance ran out. Your private apps stay
          reachable only through the panel, and nothing accrues while suspended.
        </p>
      </.callout>
      <%= if @row_funded? and @row_paid? do %>
        <.button type="button" phx-click="resume" size="sm" data-testid="access-resume">
          Resume private access
        </.button>
      <% else %>
        <p class="text-sm text-ink" data-testid="access-resume-topup">
          Top up before resuming private access. Start from <.link
            navigate={@billing_path}
            class="underline underline-offset-2 hover:text-ink"
            data-testid="access-resume-topup-link"
          >
            Billing
          </.link>.
        </p>
      <% end %>
    </div>
    """
  end

  # §4.1's attached half: one row per paired app — name, status, the
  # tailnet address (hostname + domain + route_key, rendered from the
  # row's owner-provided suffix), and Detach with no confirm
  # (reversible). The list is a stream reset on every pairing change —
  # the refetch is the update.
  attr(:gateway, AccessGateway, required: true)
  attr(:attached, :any, required: true)
  attr(:attached_empty?, :boolean, required: true)

  defp attached_card(assigns) do
    ~H"""
    <div class="min-w-0 space-y-3" data-testid="access-attached">
      <div>
        <h3 class="text-sm font-medium text-ink-muted">Attached apps</h3>
        <p class="mt-1 text-sm text-ink-muted">
          Each app gets its own address on your tailnet. Detaching is reversible. A
          detached app is reachable from the panel only again.
        </p>
      </div>

      <%!-- The pairing rows are the gateway's technical reality — the
      sunken mono register (the dav-snippet posture). The row-scoped
      Detach rides its row (the snippet's copy-button precedent);
      panel-level actions stay on cards. Friendly copy (the empty
      line, the public note) overrides the panel's mono so it keeps
      the sans register. --%>
      <div class="mono-panel min-w-0">
        <p
          :if={@attached_empty?}
          class="font-sans text-sm text-ink-muted"
          data-testid="access-attached-empty"
        >
          Nothing attached yet. Pick an app below.
        </p>

        <ul id="access-attached-rows" phx-update="stream" class="divide-y divide-line">
          <li
            :for={{dom_id, row} <- @attached}
            id={dom_id}
            class="space-y-1.5 py-3 first:pt-0 last:pb-0"
            data-testid="access-attached-row"
          >
            <div class="flex flex-wrap items-center justify-between gap-3">
              <div class="flex min-w-0 flex-wrap items-center gap-2">
                <span class="text-sm font-medium text-ink">{row.instance.name}</span>
                <.status_badge status={row.instance.status} />
              </div>
              <.button
                type="button"
                phx-click="detach"
                phx-value-instance_id={row.instance.id}
                variant="ghost"
                size="sm"
                data-testid="access-detach"
              >
                Detach
              </.button>
            </div>

            <p class="text-xs break-all text-ink" data-testid="access-attached-address">
              {address(row.route, @gateway)}
            </p>

            <%!-- §4.1: the exposure toggle can put a public instance here
                after the fact — the two switches are independent, and the
                row says so honestly instead of hiding it. --%>
            <p
              :if={row.instance.exposure == :public}
              class="font-sans text-xs text-ink-muted"
              data-testid="access-attached-public-note"
            >
              Also public. Anyone can reach it at its own address too.
            </p>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  # §4.1's attach half: the org's private instances that have no route
  # yet. Refusals are the operation's; each error lands its own line
  # here, and the section hides entirely where attaching can't work.
  attr(:attachable, :any, required: true)
  attr(:attachable_empty?, :boolean, required: true)
  attr(:attach_error, :atom, required: true)

  defp attach_card(assigns) do
    ~H"""
    <.card id="access-attach-card" class="card space-y-4" data-testid="access-attach">
      <div>
        <h3 class="text-sm font-medium text-ink-muted">Attach an app</h3>
        <p class="mt-1 text-sm text-ink-muted">
          Give a private app an address on your tailnet. Attaching never changes an
          app's exposure. The two switches stay independent.
        </p>
      </div>

      <.callout :if={@attach_error} id="access-attach-error" tone="warning">
        <p data-testid="access-attach-error">
          {attach_error_copy(@attach_error)}
        </p>
      </.callout>

      <p :if={@attachable_empty?} class="text-sm text-ink-muted" data-testid="access-attach-empty">
        No private apps waiting. Apps show up here while they are private and not
        attached yet.
      </p>

      <ul id="access-attach-rows" phx-update="stream" class="divide-y divide-line">
        <li
          :for={{dom_id, instance} <- @attachable}
          id={dom_id}
          class="flex flex-wrap items-center justify-between gap-3 py-3"
          data-testid="access-attach-row"
        >
          <div class="flex min-w-0 flex-wrap items-center gap-2">
            <span class="text-sm font-medium text-ink">{instance.name}</span>
            <.status_badge status={instance.status} />
          </div>
          <.button
            type="button"
            phx-click="attach"
            phx-value-instance_id={instance.id}
            size="sm"
            data-testid="access-attach-button"
          >
            Attach
          </.button>
        </li>
      </ul>
    </.card>
    """
  end

  # The member read policy scopes to the actor's orgs; the owner passed
  # the UX gate, so a miss here is genuinely "no gateway".
  defp fetch_gateway(org, user) do
    case AccessGateway.get_for_organization(org.id, actor: user) do
      {:ok, gateway} -> gateway
      {:error, _not_found} -> nil
    end
  end

  # The form tracks the panel's state: create when there is no gateway,
  # re-paste when there is.
  defp assign_forms(socket) do
    user = socket.assigns.current_user

    form =
      case socket.assigns.gateway do
        nil ->
          AccessGateway
          |> AshPhoenix.Form.for_create(:create, actor: user, as: "gateway")
          |> to_form()

        gateway ->
          gateway
          |> AshPhoenix.Form.for_update(:update_credential, actor: user, as: "gateway")
          |> to_form()
      end

    assign(socket, form: form)
  end

  # The create form gets the panel-owned inputs merged in; the re-paste
  # form takes its payload as-is (its action has no other inputs).
  defp form_params(params, socket) do
    if socket.assigns.form.source.type == :create do
      panel_params(params, socket)
    else
      params
    end
  end

  # The panel supplies the two create inputs it doesn't render: the org
  # (the page org — the create names it, #408) and the price snapshot
  # the row keeps.
  defp panel_params(params, socket) do
    Map.merge(params, %{
      "organization_id" => socket.assigns.org.id,
      "monthly_cents" => to_string(socket.assigns.price_cents)
    })
  end

  # The auth key never re-renders: ADR-0039 §4 forbids any read-back,
  # and a validate round-trip is one — the typed value would land in the
  # patch payload and the input's value= attribute. The submitted params
  # were validated before this strip, and LiveView leaves a focused
  # input's text alone, so typing survives; an unfocused field simply
  # comes back empty (the backups panel's secret-field posture). The
  # DOM-driven submit still sends whatever the browser holds. The strip
  # targets the changeset's ARGUMENT — that is what AshPhoenix's
  # input_value reads first, not the params maps.
  defp clear_key_display(%Phoenix.HTML.Form{source: %AshPhoenix.Form{} = ash_form} = form) do
    %{form | source: strip_key_argument(ash_form)}
  end

  defp strip_key_argument(ash_form) do
    %{ash_form | source: Ash.Changeset.set_argument(ash_form.source, :auth_key, "")}
  end

  # A failed submit rediscovers the form from the row — which has no
  # key — and carries only the errored form's field errors, so the
  # submitted key never echoes back (ADR-0039 §4; the backups panel's
  # secret-field posture).
  defp rebuild_form_with_errors(socket, errored_form) do
    socket
    |> assign_forms()
    |> then(fn socket ->
      errors = AshPhoenix.Form.errors(errored_form)

      assign(socket, form: %{socket.assigns.form | errors: errors})
    end)
  end

  # A policy denial arrives as a Forbidden error inside the form — not
  # a field error an input can render. The flash is the friendly copy;
  # the empty state's own hint names the fix before the click. (The
  # form path carries the INNER Policy error; the code-interface resume
  # path carries the Forbidden class.)
  defp forbidden?(form) do
    Enum.any?(form.source.source.errors, &match?(%Ash.Error.Forbidden.Policy{}, &1))
  end

  # The code interface wraps a refused filtered write (the resume's row
  # filter) as Invalid carrying StaleRecord — the settings form's stale
  # marker, error-class shape.
  defp stale_gateway?(%Ash.Error.Invalid{errors: errors}) do
    Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))
  end

  # Defensive: code-interface failures are always error classes (the
  # Forbidden arm is caught before this), so no test can land a bare
  # term here; the clause keeps a future shape from crashing the flash.
  # coveralls-ignore-next-line
  defp stale_gateway?(_error), do: false

  # Two wallets in play, named so they can't be conflated:
  #
  # - `create_*` — the wallet an ENABLE create bills. The create names
  #   the page org (#408), so the empty state's hints read that wallet
  #   on every mount.
  # - `row_*` — the gateway ROW's org wallet: resume spends the row's
  #   org, so the suspended panel's affordance reads that.
  defp refresh_wallet_gates(socket) do
    create_org_id = create_wallet_org_id(socket)
    row_org_id = row_wallet_org_id(socket.assigns.gateway)

    socket
    |> assign(
      create_funded?: wallet_funded?(create_org_id),
      create_paid?: wallet_paid?(create_org_id)
    )
    |> assign(
      row_funded?: wallet_funded?(row_org_id),
      row_paid?: wallet_paid?(row_org_id)
    )
  end

  # The enable create names the page org (#408), so the page org's
  # wallet IS the create's billing wallet — on the :personal mount too,
  # where the page org is the actor's personal org. The old divergence
  # (the create pinning the actor's personal org on org pages, hints
  # following it) closed with the context deploy.
  defp create_wallet_org_id(socket), do: socket.assigns.org.id

  defp row_wallet_org_id(nil), do: nil
  defp row_wallet_org_id(%AccessGateway{organization_id: org_id}), do: org_id

  # nil = no resolvable wallet (no row yet / no personal org): fail
  # closed — the empty state's hints show, nothing else reads these.
  defp wallet_funded?(nil), do: false
  defp wallet_funded?(org_id), do: ActorOrgWalletFunded.org_funded?(org_id)

  defp wallet_paid?(nil), do: false
  defp wallet_paid?(org_id), do: ActorOrgHasPaid.org_paid?(org_id)

  # ---- Pairing data + copy (§4.1) ----

  # The operation is the authority (state, exposure, org); the error map
  # is §4.1's copy contract — each refusal gets its own honest line.
  defp attach(socket, instance) do
    case Infrastructure.attach_instance(socket.assigns.gateway, instance) do
      {:ok, _route} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{instance.name} attached. Its tailnet address is below.")
         |> assign(attach_error: nil)
         |> refresh_pairing()}

      {:error, :gateway_not_active} ->
        {:noreply, assign(socket, attach_error: :gateway_not_active)}

      {:error, :pool_exhausted} ->
        {:noreply, assign(socket, attach_error: :pool_exhausted)}

      {:error, :tailnet_domain_missing} ->
        {:noreply, assign(socket, attach_error: :tailnet_domain_missing)}

      {:error, _cluster_or_stale} ->
        {:noreply, assign(socket, attach_error: :cluster)}
    end
  end

  # Detach never changes exposure (the two switches are independent),
  # so the flash says what the instance is actually left as — the
  # public-but-attached corner detaches back to public, not panel-only.
  defp detach_flash(%Instance{exposure: :private} = instance) do
    "#{instance.name} detached. Reachable from the panel only again."
  end

  defp detach_flash(%Instance{} = instance) do
    "#{instance.name} detached. Its public address still works."
  end

  # Both lists refetch wholesale: the pairing table is small, and every
  # refetch reads the rows fresh. What triggers a refetch is bounded —
  # this panel's own actions and gateway state moves; AccessRoute has no
  # notifier, so ANOTHER tab's attach or an exposure toggle elsewhere
  # does not land here until then (a stale row's click converges through
  # the operation's own guards). The emptiness flags ride alongside —
  # streams can't be counted in the template.
  defp refresh_pairing(socket) do
    {attached, attachable} =
      pairing_lists(socket.assigns.gateway, socket.assigns.org, socket.assigns.current_user)

    socket
    |> stream(:attached, attached, reset: true)
    |> stream(:attachable, attachable, reset: true)
    |> assign(attached_empty?: attached == [], attachable_empty?: attachable == [])
  end

  defp pairing_lists(nil, _org, _user), do: {[], []}

  defp pairing_lists(gateway, org, user) do
    attached = attached_rows(gateway, user)
    taken = MapSet.new(attached, & &1.route.instance_id)

    attachable =
      org.id
      |> Instance.list_for_organization!(actor: user)
      |> Enum.filter(&private_and_free?(&1, taken))
      |> Enum.sort_by(&{&1.name, &1.id})

    {Enum.sort_by(attached, &{&1.instance.name, &1.route.id}), attachable}
  end

  # §4.1's filter: exposure == :private with no existing route. A
  # public-but-attached row keeps its route (the switches are
  # independent), and its instance is rightly absent from this list.
  defp private_and_free?(%Instance{exposure: :private} = instance, taken),
    do: not MapSet.member?(taken, instance.id)

  defp private_and_free?(%Instance{}, _taken), do: false

  # The routes ride the route read policy (member-scoped through the
  # gateway); each row's instance loads under the instance read policy
  # the same way — the FK cascades the route with its instance, so a
  # row always has one.
  defp attached_rows(gateway, user) do
    gateway.id
    |> AccessRoute.list_for_gateway!(actor: user)
    |> Ash.load!(:instance, actor: user)
    |> Enum.map(&%{route: &1, instance: &1.instance})
  end

  # The states the attach operation accepts (AttachInstance's guard) —
  # the UI mirrors the authority, the operation keeps the last word.
  defp pairing_open?(%AccessGateway{state: state}), do: state in [:active, :provisioning]

  # Where the sections hide, one honest line says why (§4.1's banner:
  # attach while suspended is refused, so the section isn't offered).
  defp pairing_paused_copy(%AccessGateway{state: :suspended}) do
    "Attaching is paused while private access is suspended. Resume it to bring your apps' addresses back."
  end

  defp pairing_paused_copy(%AccessGateway{state: :needs_attention}) do
    "Attaching is paused while the gateway isn't connected. Reconnect with a fresh key first."
  end

  defp pairing_paused_copy(%AccessGateway{state: :destroying}) do
    "Attaching is unavailable. Private access is being removed."
  end

  # The open states render the sections instead — nil hides the note.
  defp pairing_paused_copy(%AccessGateway{}), do: nil

  # §4.1's error map: each refusal in the operation's own words.
  defp attach_error_copy(:gateway_not_active) do
    "Private access isn't connected yet. Wait for Connected, then attach again."
  end

  defp attach_error_copy(:pool_exhausted) do
    "This gateway's addresses are all in use. Detach an app to free one."
  end

  # The migration-window row only: every gateway created after the
  # column lands carries its domain. The fix is the re-paste form.
  defp attach_error_copy(:tailnet_domain_missing) do
    "This gateway needs its tailnet domain. Reconnect with your key and fill it in first."
  end

  defp attach_error_copy(_cluster_or_stale) do
    "Couldn't attach. Try again."
  end

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

  # §4.1's address shape: hostname + tailnet domain + route_key. The
  # domain comes from the row (the owner's, provided at enable/re-paste
  # — with PVC state the node's FQDN never leaves the pod), so the
  # address is the concrete thing the gateway serves. The placeholder
  # arm is the backfill window only: a row created before the column
  # existed, until its owner re-pastes.
  defp address(route, %AccessGateway{tailnet_domain: nil} = gateway) do
    "#{gateway.hostname}.<your-tailnet>.ts.net:#{route.route_key}"
  end

  defp address(route, %AccessGateway{} = gateway) do
    "#{gateway.hostname}.#{gateway.tailnet_domain}:#{route.route_key}"
  end

  # The recovery state shows the re-paste form outright (the ADR's
  # reconnect); everywhere else it stays collapsed behind the toggle.
  defp repaste_open_for(%AccessGateway{state: :needs_attention}), do: true
  defp repaste_open_for(_gateway), do: false

  defp state_of(nil), do: nil
  defp state_of(%AccessGateway{state: state}), do: state

  defp monthly_cents do
    # The panel's rate display reads the platform's one accessor —
    # never the config directly.
    AccessGateway.monthly_cents()
  end
end
