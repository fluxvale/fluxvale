defmodule FluxValeWeb.SettingsLive do
  @moduledoc """
  Account settings (#285 T5): the username rename (the #279 confirm-step
  pattern, bound to its proposal like the org slug rename) and email
  management over the T3 operations — add (a sign-in code goes to the
  new inbox; the code IS the proof), verify, set-primary, remove.

  The domain owns every invariant — the email cap, pending-only claims,
  the claim-expiry window, set-primary's verified-only guard, and the
  remove guards (frozen mirror, primary, last verified). The UI mirrors
  those guards only to DISABLE buttons — every action still runs through
  the operations, so a crafted or stale event meets the domain's own
  refusal, rendered as copy.
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Identity
  alias FluxVale.Identity.UserEmail

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    {:ok,
     socket
     |> assign(username_form: build_username_form(user), pending_username: nil)
     |> assign(
       add_form: to_form(%{"address" => ""}),
       verify_form: to_form(%{"code" => ""})
     )
     |> assign(emails: present(mine(user), user))}
  end

  # -- Username rename (the #279 confirm-step pattern) -------------------

  @impl Phoenix.LiveView
  def handle_event("validate", %{"user" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.username_form, params)

    {:noreply, assign(socket, username_form: form, pending_username: rearm(socket, form, params))}
  end

  def handle_event("save-username", %{"user" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.username_form, params)

    cond do
      # Invalid input never earns the confirm step — the field error
      # shows first (validation before arming, the #279 posture).
      AshPhoenix.Form.errors(form) != [] ->
        {:noreply, assign(socket, username_form: form, pending_username: nil)}

      # A change lands ONLY through the confirm step: every save
      # (re-)arms the panel for exactly the submitted username.
      params["username"] != (socket.assigns.current_user.username || "") ->
        {:noreply, assign(socket, username_form: form, pending_username: params["username"])}

      true ->
        {:noreply, assign(socket, username_form: form, pending_username: nil)}
    end
  end

  # Guarded: only an armed panel can apply a rename, and it applies the
  # armed value — an unarmed click is a no-op (any edit disarms first,
  # see rearm/3), so a crafted event can never rename on its own.
  def handle_event("confirm-username", _params, socket) do
    case socket.assigns.pending_username do
      nil ->
        {:noreply, socket}

      _armed ->
        outcome =
          AshPhoenix.Form.submit(socket.assigns.username_form,
            params: socket.assigns.username_form.params
          )

        case outcome do
          {:ok, updated} ->
            user = %{socket.assigns.current_user | username: updated.username}

            {:noreply,
             socket
             # username too: OrgNav's chrome assign feeds the switcher's
             # Personal row — the menu and the switcher must move together
             |> assign(current_user: user, username: updated.username, pending_username: nil)
             |> assign(username_form: build_username_form(user))
             |> assign(emails: present(mine(user), user))
             |> put_flash(:info, "Username updated.")}

          {:error, form} ->
            # The unique-username conflict lands here as the form's field
            # error ("has already been taken") — friendly, not a crash. No
            # stale-form flash: usernames address nothing (see the action's
            # comment), so a stale view has nothing to lose.
            {:noreply, assign(socket, username_form: form, pending_username: nil)}
        end
    end
  end

  def handle_event("cancel-username", _params, socket) do
    {:noreply, assign(socket, :pending_username, nil)}
  end

  # -- Email management (the T3 operations) ------------------------------

  def handle_event("add-email", %{"address" => address}, socket) do
    user = socket.assigns.current_user

    case Identity.add_email(user, address) do
      {:ok, _pending_row} ->
        {:noreply,
         socket
         |> assign(add_form: to_form(%{"address" => ""}), emails: present(mine(user), user))
         |> put_flash(
           :info,
           "We sent a sign-in code to #{address} — enter it below to verify."
         )}

      {:error, :throttled} ->
        error(socket, "Please wait a minute before requesting another code.")

      {:error, :not_allowed} ->
        error(socket, "That address can't sign in yet — ask an admin for access.")

      {:error, :delivery_failed} ->
        error(socket, "We couldn't send the email — please wait a minute, then try again.")

      # The resource refused the claim itself: the cap (a distinct
      # message from EnforceEmailCap), a malformed address, or the
      # global unique_address on a live claim / a verified row.
      {:error, refused} ->
        cond do
          cap_hit?(refused) ->
            error(
              socket,
              "You've reached the limit of #{UserEmail.max_emails_per_user()} email " <>
                "addresses — remove one first."
            )

          UserEmail.valid_address?(address) ->
            error(
              socket,
              "That address is already claimed — if it's yours and the code expired, " <>
                "remove the pending claim and add it again."
            )

          true ->
            error(socket, "That doesn't look like an email address — check it and try again.")
        end
    end
  end

  def handle_event("verify-email", %{"row_id" => row_id, "code" => code}, socket) do
    user = socket.assigns.current_user

    case Identity.verify_email(user, row_id, code) do
      {:ok, _verified} ->
        {:noreply,
         socket
         |> assign(emails: present(mine(user), user))
         |> put_flash(:info, "Address verified.")}

      {:error, :not_pending} ->
        error(socket, "That address is already verified.")

      {:error, :no_active_code} ->
        error(
          socket,
          "That code has expired — remove the address and add it again for a fresh code."
        )

      {:error, :wrong_code} ->
        error(socket, "That code didn't match. Try again.")

      {:error, :locked_out} ->
        error(
          socket,
          "Too many attempts — remove the address and add it again for a fresh code."
        )

      {:error, :not_found} ->
        error(socket, "That address claim is gone — refresh the page.")

      {:error, _other} ->
        error(socket, "Something went wrong — try again.")
    end
  end

  def handle_event("set-primary", %{"row_id" => row_id}, socket) do
    user = socket.assigns.current_user

    case Identity.set_primary_email(user, row_id) do
      {:ok, _promoted} ->
        {:noreply,
         socket
         |> assign(emails: present(mine(user), user))
         |> put_flash(:info, "Primary address updated.")}

      {:error, :not_found} ->
        error(socket, "That address is gone — refresh the page.")

      {:error, refused} ->
        error(socket, "Couldn't promote — the address #{refusal_message(refused)}")
    end
  end

  def handle_event("remove-email", %{"row_id" => row_id}, socket) do
    user = socket.assigns.current_user

    case Identity.remove_email(user, row_id) do
      :ok ->
        {:noreply,
         socket
         |> assign(emails: present(mine(user), user))
         |> put_flash(:info, "Address removed.")}

      {:error, :not_found} ->
        error(socket, "That address is gone — refresh the page.")

      {:error, refused} ->
        error(socket, "Couldn't remove — the address #{refusal_message(refused)}")
    end
  end

  # -- Helpers -----------------------------------------------------------

  # The arm survives only while the field still holds exactly what was
  # armed and the input stays valid: an edit, a revert to the current
  # username, or a format error disarms, and the next save re-arms. The
  # applied rename is therefore always a value the visible copy named.
  defp rearm(socket, form, params) do
    armed = socket.assigns.pending_username

    cond do
      is_nil(armed) -> nil
      AshPhoenix.Form.errors(form) != [] -> nil
      params["username"] != armed -> nil
      true -> armed
    end
  end

  defp build_username_form(user) do
    user
    |> AshPhoenix.Form.for_update(:set_username, actor: user, as: "user")
    |> to_form()
  end

  # The first field message of a domain refusal (the guards' copy:
  # "is the primary address — make another address primary first", …).
  defp refusal_message(%Ash.Error.Invalid{errors: errors}) do
    found = Enum.find(errors, &is_binary(Map.get(&1, :message)))

    case found do
      nil -> "was refused — try again"
      refusal -> Map.get(refusal, :message)
    end
  end

  defp refusal_message(_other), do: "was refused — try again"

  defp error(socket, message), do: {:noreply, put_flash(socket, :error, message)}

  # The actor's own rows (the :mine owner-scoped read), presentation-
  # ordered: the primary, then verified by age, then pending claims. The
  # email cap bounds the list.
  defp mine(user) do
    UserEmail
    |> Ash.Query.for_read(:mine, %{}, actor: user)
    |> Ash.read!()
    |> Enum.sort_by(&{not &1.is_primary, is_nil(&1.verified_at), &1.created_at})
  end

  # The RemoveGuard invariants, mirrored for the disabled states — the
  # domain still enforces every one of them (the button is UX, not the
  # guard): never the frozen mirror, never the primary, never the last
  # verified. A pending row is always removable — the abandon affordance
  # (a claim can never be primary, the frozen mirror, or verified).
  defp remove_allowed?(row, user, verified_count) do
    cond do
      to_string(row.address) == to_string(user.email) -> false
      row.is_primary -> false
      not is_nil(row.verified_at) and verified_count == 1 -> false
      true -> true
    end
  end

  # The cap refusal carries EnforceEmailCap's own message on the
  # Invalid's members — matched by prefix so the wording and the value
  # stay the domain's (single-sourced at max_emails_per_user/0).
  defp cap_hit?(%Ash.Error.Invalid{} = invalid) do
    Enum.any?(invalid.errors, fn member ->
      message = message_of(member)
      String.starts_with?(message, "too many email addresses")
    end)
  end

  defp cap_hit?(_other), do: false

  defp message_of(%{message: message}) when is_binary(message), do: message
  defp message_of(_other), do: ""

  defp present(rows, user) do
    verified_count = Enum.count(rows, &(not is_nil(&1.verified_at)))

    Enum.map(rows, fn row ->
      %{
        row: row,
        removable?: remove_allowed?(row, user, verified_count),
        promotable?: not is_nil(row.verified_at) and not row.is_primary
      }
    end)
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
    >
      <div class="mx-auto max-w-3xl space-y-8">
        <div>
          <h1 class="text-2xl font-semibold tracking-tight text-ink" data-testid="settings-title">
            Account settings
          </h1>
          <p class="mt-1 text-sm text-ink-muted">Your handle and the addresses you sign in with.</p>
        </div>

        <.card id="settings-username-card" class="space-y-4">
          <div>
            <h2 class="text-base font-medium text-ink">Username</h2>
            <p class="mt-1 text-sm text-ink-muted">
              Your handle across FluxVale. The old handle is released for anyone to claim —
              no reservations.
            </p>
          </div>

          <.form
            for={@username_form}
            id="username-form"
            phx-change="validate"
            phx-submit="save-username"
            class="space-y-4"
          >
            <.input
              field={@username_form[:username]}
              label="Username"
              maxlength={39}
              required
              data-testid="username-input"
            />

            <.callout
              :if={@pending_username}
              id="username-confirm"
              tone="warning"
              title="Rename your account?"
              data-testid="username-confirm"
            >
              <p>
                Your handle becomes <span class="font-mono">{@pending_username}</span>. The old
                handle is released immediately and no redirect is created — anything that
                addressed it stops.
              </p>
              <div class="flex gap-3 pt-1">
                <.button
                  type="button"
                  phx-click="confirm-username"
                  size="sm"
                  data-testid="confirm-username"
                >
                  Rename account
                </.button>
                <.button
                  variant="ghost"
                  type="button"
                  phx-click="cancel-username"
                  size="sm"
                  data-testid="cancel-username"
                >
                  Cancel
                </.button>
              </div>
            </.callout>

            <div class="flex justify-end">
              <.button type="submit" data-testid="username-save">
                Save changes
              </.button>
            </div>
          </.form>
        </.card>

        <.card id="settings-emails-card" class="space-y-4">
          <div>
            <h2 class="text-base font-medium text-ink">Email addresses</h2>
            <p class="mt-1 text-sm text-ink-muted">
              Any verified address signs you in; the primary is where billing writes to.
            </p>
          </div>

          <div class="divide-y divide-line">
            <div
              :for={item <- @emails}
              id={"email-row-#{item.row.id}"}
              class="flex flex-wrap items-start justify-between gap-3 py-3"
              data-testid="email-row"
            >
              <div class="min-w-0 space-y-1">
                <div class="flex flex-wrap items-center gap-2">
                  <span class="break-all text-sm font-medium text-ink">{item.row.address}</span>
                  <.badge
                    :if={item.row.is_primary}
                    tone="primary"
                    data-testid={"email-primary-#{item.row.id}"}
                  >
                    Primary
                  </.badge>
                  <.badge
                    :if={not is_nil(item.row.verified_at)}
                    tone="success"
                    data-testid={"email-verified-#{item.row.id}"}
                  >
                    Verified
                  </.badge>
                  <.badge
                    :if={is_nil(item.row.verified_at)}
                    tone="warning"
                    data-testid={"email-pending-#{item.row.id}"}
                  >
                    Pending
                  </.badge>
                </div>

                <%!-- A pending claim is a claim on an inbox, not an address
                you own yet: the code that lands there is the proof — the
                same sign-in code, no separate token ("one proof"). --%>
                <.form
                  :if={is_nil(item.row.verified_at)}
                  for={@verify_form}
                  id={"verify-form-#{item.row.id}"}
                  phx-submit="verify-email"
                  class="flex items-end gap-2"
                >
                  <input type="hidden" name="row_id" value={item.row.id} />
                  <div class="w-32">
                    <%!-- one shared form struct names every row's field the
                    same — the explicit id keeps the DOM ids unique per row
                    (the cap allows several pending claims on one page) --%>
                    <.input
                      field={@verify_form[:code]}
                      id={"verify-code-input-#{item.row.id}"}
                      type="text"
                      inputmode="numeric"
                      maxlength={6}
                      label="Sign-in code"
                      data-testid={"verify-code-#{item.row.id}"}
                    />
                  </div>
                  <.button type="submit" size="sm" data-testid={"verify-submit-#{item.row.id}"}>
                    Verify
                  </.button>
                </.form>
              </div>

              <div class="flex shrink-0 items-center gap-2">
                <%!-- Disabled mirrors the domain's guards (SetPrimary's
                verified-only); the domain still enforces them. --%>
                <.button
                  :if={not item.row.is_primary}
                  type="button"
                  phx-click="set-primary"
                  phx-value-row_id={item.row.id}
                  variant="secondary"
                  size="sm"
                  disabled={not item.promotable?}
                  data-testid={"email-set-primary-#{item.row.id}"}
                >
                  Set primary
                </.button>
                <%!-- Disabled mirrors RemoveGuard (frozen mirror / primary /
                last verified); the domain still enforces them — a crafted
                click meets the refusal, not the UI's word for it. --%>
                <.button
                  type="button"
                  phx-click="remove-email"
                  phx-value-row_id={item.row.id}
                  variant="ghost"
                  size="sm"
                  disabled={not item.removable?}
                  data-testid={"email-remove-#{item.row.id}"}
                >
                  Remove
                </.button>
              </div>
            </div>
          </div>

          <.form for={@add_form} id="add-email-form" phx-submit="add-email" class="space-y-3">
            <div class="flex items-end gap-2">
              <.input
                field={@add_form[:address]}
                type="email"
                label="Add an address"
                placeholder="you@example.com"
                data-testid="add-email-input"
              />
              <.button type="submit" size="sm" data-testid="add-email-submit">
                Add address
              </.button>
            </div>
            <p class="text-xs text-ink-subtle">
              We'll send a sign-in code to the new address — enter it here to verify you own
              the inbox. A pending claim expires after {UserEmail.claim_ttl_minutes()} minutes.
            </p>
          </.form>
        </.card>
      </div>
    </Layouts.app>
    """
  end
end
