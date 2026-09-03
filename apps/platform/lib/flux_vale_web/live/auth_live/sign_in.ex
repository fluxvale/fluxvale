defmodule FluxValeWeb.AuthLive.SignIn do
  @moduledoc """
  Passwordless sign-in (ADR-0003, #21): email → code-sent → code entry.

  The verify step never mints the session inside the LiveView — success
  hands a one-shot native form POST to `SessionController`, so the token
  travels in a POST body (never a URL — the magic-link lesson) and the
  session write happens in a proper Plug world.
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Identity

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="mx-auto max-w-sm space-y-6 py-8">
        <div class="space-y-2">
          <h1 class="text-2xl font-bold tracking-tight">Sign in to FluxVale</h1>
          <p class="text-sm opacity-70">
            Passwordless — we'll email you a one-time code.
          </p>
        </div>

        <.form
          :if={@step == :email}
          for={@form}
          id="email-form"
          phx-submit="request-code"
          class="space-y-4"
        >
          <.input
            field={@form[:email]}
            type="email"
            label="Email address"
            placeholder="you@example.com"
            required
            autofocus
          />
          <.button type="submit" class="w-full" phx-disable-with="Sending…">
            Send code
          </.button>
        </.form>

        <div :if={@step == :code} class="space-y-4">
          <p class="text-sm opacity-80">
            We sent a 6-digit code to <span class="font-medium">{@email}</span>.
            It expires in 10 minutes.
          </p>

          <.form
            for={@form}
            id="code-form"
            phx-submit="verify"
            action={~p"/auth/session"}
            method="post"
            phx-trigger-action={@trigger_submit}
            class="space-y-4"
          >
            <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
            <input type="hidden" name="token" value={@token} />
            <.input
              field={@form[:code]}
              type="text"
              inputmode="numeric"
              autocomplete="one-time-code"
              maxlength="6"
              label="Sign-in code"
              required
              autofocus
            />
            <.button type="submit" class="w-full" phx-disable-with="Signing in…">
              Verify &amp; sign in
            </.button>
          </.form>

          <button phx-click="change-email" class="text-sm link link-hover">
            Use a different email
          </button>
        </div>
      </div>
    </Layouts.app>
    """
  end

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(step: :email, email: nil, token: nil, trigger_submit: false)
     |> assign(form: to_form(%{"email" => ""}))}
  end

  def handle_event("request-code", %{"email" => email}, socket) do
    case Identity.request_auth_code(email) do
      :ok ->
        {:noreply,
         socket
         |> assign(step: :code, email: email)
         |> assign(form: to_form(%{"code" => ""}))
         |> put_flash(:info, "Code sent — check your inbox.")}

      {:error, :throttled} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Please wait a minute before requesting another code."
         )}

      {:error, :delivery_failed} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "We couldn't send the email right now — please try again shortly."
         )}
    end
  end

  def handle_event("verify", %{"code" => code}, socket) do
    case Identity.verify_auth_code(socket.assigns.email, code) do
      {:ok, _user, token} ->
        {:noreply, assign(socket, token: token, trigger_submit: true)}

      {:error, :locked_out} ->
        {:noreply,
         socket
         |> assign(step: :email)
         |> assign(form: to_form(%{"email" => socket.assigns.email}))
         |> put_flash(:error, "Too many attempts — request a fresh code.")}

      {:error, _reason} ->
        # Uniform message: unknown address and wrong code look identical
        {:noreply, put_flash(socket, :error, "That code didn't match. Try again.")}
    end
  end

  def handle_event("change-email", _params, socket) do
    {:noreply,
     socket
     |> assign(step: :email, token: nil, trigger_submit: false)
     |> assign(form: to_form(%{"email" => socket.assigns.email}))}
  end
end
