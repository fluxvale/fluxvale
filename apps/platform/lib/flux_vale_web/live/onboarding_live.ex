defmodule FluxValeWeb.OnboardingLive do
  @moduledoc """
  The show-once first-run flow (#831, D1): username → agent option →
  how-it-works → dashboard. Entry is the `/` swap's nil-stamp gate
  (PageController.home, D1 — one nudge deep, deep links stay ungated).
  The step machine lives in LiveView assigns; the only write is the
  final :finish_onboarding stamp (D4), so Finish and skip-at-any-step
  run the same call and land `/`. Nothing blocks — skip forgoes
  everything after the current step, by decision.

  The username step reuses the settings rename machinery verbatim (D2):
  the derived handle pre-filled, an edit through the existing
  `:set_username` action — ValidUsername's field errors and the
  unique-username identity's conflict copy surface exactly as
  SettingsLive renders them. Accepting the suggestion as-is advances
  with NO action call. SettingsLive's confirm-step is deliberately not
  armed here: one Save, no second look — the step itself IS the
  deliberate choice (the confirm pattern stays the post-onboarding
  rename's guard, where the old handle has things pointing at it).

  The agent step is #817's modal + AgentPanel reuse (D3): the same body
  as `/agent` in the same `<.modal>`, computed at open from OrgNav's
  assigns, nothing persisted. The dismissal card stays `/agent`'s — the
  dashboard's button remains the post-onboarding path for skippers.
  """

  use FluxValeWeb, :live_view

  alias FluxValeWeb.AgentPanel
  alias FluxValeWeb.AgentPrompt

  @steps [:username, :agent, :walkthrough]

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    if user.onboarded_at do
      # D4's show-once guarantee: a stamped account hitting /onboarding
      # directly has already walked (or skipped) the flow.
      {:ok, push_navigate(socket, to: ~p"/")}
    else
      {:ok,
       socket
       |> assign(step: :username, agent_modal: nil)
       |> assign(username_form: build_username_form(user))}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("validate-username", %{"user" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.username_form, params)
    {:noreply, assign(socket, username_form: form)}
  end

  def handle_event("save-username", %{"user" => params}, socket) do
    user = socket.assigns.current_user

    if params["username"] == user.username do
      # Accept-as-is: the unchanged suggestion IS the deliberate choice
      # — advance with no action call (the D2 posture).
      {:noreply, advance(socket)}
    else
      {:noreply, submit_username(socket, params)}
    end
  end

  def handle_event("continue-agent", _params, socket) do
    {:noreply, advance(socket)}
  end

  # #817's lazy-at-open computation, the dashboard modal's exact calls —
  # from the OrgNav assigns this view already carries. Closing drops it
  # all; nothing is stored (D3).
  def handle_event("show-agent-prompt", _params, socket) do
    org = AgentPanel.org_from_assigns(socket.assigns)
    ctx = AgentPrompt.context(org && org.name, org && org.slug)

    {:noreply,
     assign(socket, :agent_modal, %{
       prompt: AgentPrompt.prompt(ctx),
       snippets: AgentPrompt.clients_with_code(ctx),
       snippet_note: AgentPrompt.snippet_note(),
       what_it_will_do: AgentPrompt.what_it_will_do()
     })}
  end

  def handle_event("close-agent-modal", _params, socket) do
    {:noreply, assign(socket, :agent_modal, nil)}
  end

  # Skip at any step and Finish at the end are the same call (D4): one
  # stamp, everything after the current step forgone.
  def handle_event("skip", _params, socket), do: finish_and_land(socket)

  def handle_event("finish", _params, socket), do: finish_and_land(socket)

  # One step forward, gated by the machine — a crafted frame from the
  # last step (or an unknown one) finds no next step and stays put (the
  # invite-accept fence posture).
  defp advance(socket) do
    index = Enum.find_index(@steps, &(&1 == socket.assigns.step))
    next = index && Enum.at(@steps, index + 1)

    if next do
      assign(socket, :step, next)
    else
      socket
    end
  end

  # An edit rides :set_username verbatim (D2) — the form already carries
  # the owner actor, so ValidUsername and the unique-username identity
  # are the only rules, and their refusals land on the form's field
  # errors exactly as settings renders them.
  defp submit_username(socket, params) do
    form = AshPhoenix.Form.validate(socket.assigns.username_form, params)

    if AshPhoenix.Form.errors(form) != [] do
      # Invalid input never earns a submit — the field error shows
      # first (settings' posture).
      assign(socket, username_form: form)
    else
      case AshPhoenix.Form.submit(form, params: form.params) do
        {:ok, updated} ->
          user = %{socket.assigns.current_user | username: updated.username}

          socket
          |> assign(current_user: user, username: updated.username)
          |> assign(username_form: build_username_form(user))
          |> advance()

        {:error, form} ->
          assign(socket, username_form: form)
      end
    end
  end

  defp finish_and_land(socket) do
    user = socket.assigns.current_user

    result =
      user
      |> Ash.Changeset.for_update(:finish_onboarding, %{})
      |> Ash.update(actor: user)

    case result do
      {:ok, _stamped} ->
        {:noreply, push_navigate(socket, to: ~p"/")}

      # coveralls-ignore-start — untestable by construction: the actor
      # IS the record owner (the policy admits it) and the action takes
      # no input, so the only refusals are infrastructure (DB down, the
      # documented unreasonable class). Staying put is honest — the nil
      # stamp re-gates `/` on the next visit.
      {:error, _refused} ->
        {:noreply, put_flash(socket, :error, "Something went wrong. Try again.")}
        # coveralls-ignore-stop
    end
  end

  defp build_username_form(user) do
    user
    |> AshPhoenix.Form.for_update(:set_username, actor: user, as: "user")
    |> to_form()
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
      <div class="appgram contents" data-testid="onboarding-flow">
        <section class="band">
          <div class="wrap pt-8 pb-10">
            <div class="rise">
              <p class="eyebrow">First run</p>
              <h1 class="page-title mt-1.5">Welcome to FluxVale</h1>
              <p class="mt-2 max-w-2xl text-base text-ink-muted">
                Three quick beats, then your dashboard. Skip anything — nothing blocks.
              </p>
            </div>
          </div>
        </section>

        <section class="wrap pt-10 pb-16">
          <div class="rise" data-testid={"onboarding-step-#{@step}"}>
            <%= case @step do %>
              <% :username -> %>
                <div class="max-w-2xl space-y-4">
                  <h2 class="text-lg font-semibold tracking-tight text-ink">
                    Choose your handle
                  </h2>
                  <p class="text-sm text-ink-muted">
                    This names you across FluxVale. Keep the suggestion or pick your own —
                    you can rename later in settings.
                  </p>
                  <.form
                    for={@username_form}
                    id="onboarding-username-form"
                    phx-change="validate-username"
                    phx-submit="save-username"
                    class="space-y-4"
                  >
                    <.input
                      field={@username_form[:username]}
                      label="Username"
                      maxlength={39}
                      required
                      data-testid="onboarding-username-input"
                    />

                    <div class="flex items-center gap-3">
                      <.button type="submit" data-testid="onboarding-username-continue">
                        Continue
                      </.button>
                      <.button
                        type="button"
                        variant="ghost"
                        phx-click="skip"
                        data-testid="onboarding-skip"
                      >
                        Skip
                      </.button>
                    </div>
                  </.form>
                </div>
              <% :agent -> %>
                <div class="max-w-2xl space-y-4">
                  <h2 class="text-lg font-semibold tracking-tight text-ink">
                    Or hand it to your agent
                  </h2>
                  <p class="text-sm text-ink-muted">
                    One prompt connects the agent you already use. It proposes an app and
                    its price, waits for your yes, and deploys.
                  </p>

                  <div class="flex flex-wrap items-center gap-3">
                    <.button
                      type="button"
                      phx-click="show-agent-prompt"
                      data-testid="onboarding-agent-show-prompt"
                    >
                      Show the prompt
                    </.button>
                    <.button
                      type="button"
                      variant="secondary"
                      phx-click="continue-agent"
                      data-testid="onboarding-agent-continue"
                    >
                      Continue
                    </.button>
                  </div>

                  <div class="flex items-center gap-4 text-sm">
                    <.link
                      navigate={~p"/agent"}
                      data-testid="onboarding-agent-open-page"
                      class="font-medium text-link transition-colors hover:text-ink"
                    >
                      Open the full page
                    </.link>
                    <button
                      type="button"
                      phx-click="skip"
                      data-testid="onboarding-skip"
                      class="font-medium text-ink-muted transition-colors hover:text-ink"
                    >
                      Skip
                    </button>
                  </div>
                </div>
              <% :walkthrough -> %>
                <div class="max-w-2xl space-y-4">
                  <h2 class="text-lg font-semibold tracking-tight text-ink">
                    How FluxVale works
                  </h2>
                  <ol class="space-y-3 text-sm text-ink-muted">
                    <li data-testid="onboarding-walkthrough-beat">
                      <span class="font-medium text-ink">Pick from the catalog</span>
                      — open source apps, ready to run.
                    </li>
                    <li data-testid="onboarding-walkthrough-beat">
                      <span class="font-medium text-ink">Deploy to your box</span>
                      — FluxVale runs it on your instance, billed hourly.
                    </li>
                    <li data-testid="onboarding-walkthrough-beat">
                      <span class="font-medium text-ink">Manage the instance</span>
                      — status, env, domains, logs.
                    </li>
                  </ol>

                  <div class="flex items-center gap-3">
                    <.button
                      type="button"
                      phx-click="finish"
                      data-testid="onboarding-walkthrough-finish"
                    >
                      Finish
                    </.button>
                    <.button
                      type="button"
                      variant="ghost"
                      phx-click="skip"
                      data-testid="onboarding-skip"
                    >
                      Skip
                    </.button>
                  </div>
                </div>
            <% end %>
          </div>
        </section>

        <%!-- D3: the #817 modal + AgentPanel body, no inner slot — the
        dismissal card is /agent's, never this flow's. --%>
        <.modal
          :if={@agent_modal}
          id="onboarding-agent-modal"
          title="Finish setup with your agent"
          on_cancel="close-agent-modal"
          testid="onboarding-agent-modal"
          class="max-w-5xl"
        >
          <AgentPanel.body
            prompt={@agent_modal.prompt}
            snippets={@agent_modal.snippets}
            snippet_note={@agent_modal.snippet_note}
            what_it_will_do={@agent_modal.what_it_will_do}
          />

          <:footer>
            <.link
              navigate={~p"/agent"}
              data-testid="onboarding-agent-panel-link"
              class="text-sm font-medium text-link transition-colors hover:text-ink"
            >
              Open the full page
            </.link>
          </:footer>
        </.modal>
      </div>
    </Layouts.app>
    """
  end
end
