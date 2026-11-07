defmodule FluxValeWeb.AdminLive.WithdrawInviteConfirm do
  @moduledoc """
  The people surface's withdraw confirm (#501): `confirm_block`'s home
  on this lane. The parent mounts exactly one instance at a time (the
  row being withdrawn), so the component's shared destructive-confirm
  testid stays safe — the contract is one confirm per panel.

  The write rides `Identity.withdraw_invite/3` with the platform-admin
  actor and authorization on — the domain policies decide, never the
  UI. The outcome travels back as a message (component handlers run in
  the LiveView process): the parent owns the list, the flash, and the
  panel's visibility.
  """

  use FluxValeWeb, :live_component

  alias FluxVale.Identity

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  # The destructive click. Refusals are one message to the parent: a
  # raced acceptance (StaleRecord — the row's filter no longer matches)
  # and a lost admin grant read the same from here, and the parent's
  # refresh makes the row tell the truth either way.
  @impl Phoenix.LiveComponent
  def handle_event("confirm-withdraw", _params, socket) do
    case Identity.withdraw_invite(socket.assigns.actor, socket.assigns.user) do
      {:ok, _withdrawn} ->
        send(self(), {:invite_withdrawn, socket.assigns.user.id})

      {:error, _changed_or_denied} ->
        send(self(), {:invite_withdraw_failed, socket.assigns.user.id})
    end

    {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def handle_event("cancel-confirm", _params, socket) do
    send(self(), {:cancel_withdraw})

    {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div data-testid="admin-people-withdraw-panel">
      <.confirm_block
        title={gettext("Withdraw the invite for %{email}?", email: @user.email)}
        body={
          gettext(
            "Their accept link stops working. The account remains inert until someone invites them again."
          )
        }
        action={gettext("Yes, withdraw this invite")}
        event="confirm-withdraw"
        action_testid="admin-people-withdraw-confirm"
        cancel_testid="admin-people-withdraw-cancel"
        myself={@myself}
      />
    </div>
    """
  end
end
