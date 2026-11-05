defmodule FluxValeWeb.FeedbackLive.CommentsIsland do
  @moduledoc """
  The post page's comments island (fluxvale/fluxvale#412, T5, ADR-0026
  S4): the comment list plus the form, mounted on the SSR post page over
  `live_render`. The initial list is server-side, so crawlers see the
  conversation.

  The gate is the owner's Nov ruling: any authenticated user may
  comment — membership and paying status irrelevant. Anonymous gets a
  sign-in CTA. The list rides a LiveView stream (newest first); a
  posted comment streams in and the heading's count moves with it.
  Body bounds render inline through the form's field errors.

  Authors render via the `author_username` calculation — the one User
  projection safe on a public surface (User reads are admin-only;
  `author_user` is never loaded here).
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Feedback.Comment
  alias FluxVale.Feedback.Post
  alias FluxValeWeb.Locale
  alias FluxValeWeb.ReturnPath
  alias FluxValeWeb.UserAuth

  require Ash.Query

  @impl Phoenix.LiveView
  def mount(_params, session, socket) do
    # No live_session carries the locale hook for a controller-embedded
    # child (the pricing-calculator posture): mount re-resolves it.
    Gettext.put_locale(FluxValeWeb.Gettext, Locale.resolve(session))

    user = UserAuth.resolve_user(session)
    post = post_by_slug(session["slug"])

    socket =
      socket
      |> assign(
        user: user,
        post: post,
        # The SSR request's own return path (#462 review): keeps the
        # query the page was loaded with, so the CTA returns to the
        # URL the visitor was reading, not just the path.
        return_to: ReturnPath.safe(session["return_to"]),
        form: form_for(user)
      )
      |> stream_initial(post)

    {:ok, socket}
  end

  # Keystroke validation: the bounds errors show inline while typing.
  # The wire nests under the form's `as`; AshPhoenix takes the inner
  # params (the deploy stepper's posture). A post deleted between the
  # SSR render and the island's connect leaves the handlers silent —
  # nothing to attach the comment to, nothing to crash on.
  @impl Phoenix.LiveView
  def handle_event("validate", _params, %{assigns: %{post: nil}} = socket) do
    {:noreply, socket}
  end

  # The anonymous island renders the sign-in CTA instead of the form
  # (form_for/1 answers nil), so a crafted validate has nothing to
  # validate — silence, not a nil dereference.
  def handle_event("validate", _params, %{assigns: %{form: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("validate", %{"comment" => params}, socket) when is_map(params) do
    form_params =
      socket.assigns.form.params
      |> Map.merge(params)
      |> Map.put("post_id", socket.assigns.post.id)

    {:noreply, assign(socket, form: AshPhoenix.Form.validate(socket.assigns.form, form_params))}
  end

  def handle_event("validate", _params, socket), do: {:noreply, socket}

  # The write never pre-checks "any authenticated user" beyond the
  # render — the action's policy is the authority; a crafted anonymous
  # submit is refused there and stays refused here.
  def handle_event("submit-comment", _params, %{assigns: %{user: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("submit-comment", _params, %{assigns: %{post: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("submit-comment", %{"comment" => params}, socket) when is_map(params) do
    # post_id is the island's own post, never the client's (a form
    # input would be caller-controlled otherwise).
    form_params =
      socket.assigns.form.params
      |> Map.merge(params)
      |> Map.put("post_id", socket.assigns.post.id)

    case AshPhoenix.Form.submit(socket.assigns.form, params: form_params) do
      {:ok, comment} ->
        comment = Ash.load!(comment, :author_username)

        {:noreply,
         socket
         |> stream_insert(:comments, comment, at: 0)
         |> assign(count: comment_count(socket.assigns.post))
         |> assign(form: form_for(socket.assigns.user))}

      # Validation and policy refusals land on the form — field errors
      # render inline under the body input.
      {:error, form} ->
        {:noreply, assign(socket, form: form)}
    end
  end

  def handle_event("submit-comment", _params, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def render(assigns) do
    # #462: the CTA's sign-in link carries the post page back through
    # sign-in — precomputed so the guard stays in ReturnPath.
    assigns = assign(assigns, sign_in_href: sign_in_href(assigns))

    ~H"""
    <section :if={@post} id="comments-island" data-testid="comments-island" class="mt-10">
      <h2 id="comments-count" class="text-lg font-semibold tracking-tight text-ink">
        {comments_label(@count)}
      </h2>

      <div id="comments" phx-update="stream" class="mt-4 space-y-4">
        <p id="comments-empty" class="hidden only:block text-sm text-ink-muted">
          {gettext("No comments yet.")}
        </p>
        <article
          :for={{dom_id, comment} <- @streams.comments}
          id={dom_id}
          data-testid="comment"
          class="rounded-panel border border-line bg-panel px-4 py-3"
        >
          <div class="flex items-baseline justify-between gap-3 text-sm">
            <span class="font-medium text-ink">{comment.author_username}</span>
            <span class="text-xs text-ink-muted">
              {FluxValeWeb.FeedbackHTML.time_ago(comment.created_at)}
            </span>
          </div>
          <p class="mt-2 text-sm leading-relaxed text-ink">
            <span class="whitespace-pre-line">{comment.body}</span>
          </p>
        </article>
      </div>

      <div :if={@form} class="mt-6">
        <.form
          for={@form}
          id="comment-form"
          phx-change="validate"
          phx-submit="submit-comment"
          class="space-y-3"
        >
          <.input
            field={@form[:body]}
            type="textarea"
            label={gettext("Add a comment")}
            placeholder={gettext("Be kind and stay on topic.")}
            rows={3}
            maxlength={5000}
            data-testid="comment-body"
          />
          <.button type="submit" data-testid="comment-submit" phx-disable-with={gettext("Posting…")}>
            {gettext("Post comment")}
          </.button>
        </.form>
      </div>

      <p :if={is_nil(@user)} class="mt-6 text-sm text-ink-muted">
        <.link
          href={@sign_in_href}
          data-testid="comment-sign-in"
          class="font-medium text-link hover:underline"
        >
          {gettext("Sign in to comment")}
        </.link>
      </p>
    </section>
    """
  end

  # --- State ------------------------------------------------------------------

  # Newest first: a posted comment streams in AT THE TOP — LiveView
  # 1.2.11's stream_insert default (at: -1) APPENDS to the rendered
  # list (appendChild in dom_patch.ts), which would land the fresh
  # comment under older ones in a newest-first list. at: 0 is explicit
  # about the top insert.
  defp stream_initial(socket, nil), do: socket

  defp stream_initial(socket, post) do
    comments =
      Comment
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.filter(post_id == ^post.id)
      |> Ash.Query.sort(created_at: :desc)
      |> Ash.Query.load(:author_username)
      |> Ash.read!(actor: nil)

    socket = stream(socket, :comments, comments)
    assign(socket, count: post.comment_count)
  end

  defp form_for(nil), do: nil

  defp form_for(user) do
    Comment
    |> AshPhoenix.Form.for_create(:create, actor: user, as: "comment")
    |> to_form()
  end

  # The CTA returns to the page the visitor was reading: the SSR
  # request's own path (query included) when the session carried it,
  # else the post path built from the slug. Both ride the shared guard.
  defp sign_in_href(%{return_to: nil, post: nil}), do: ReturnPath.sign_in_path(nil)

  defp sign_in_href(%{return_to: nil, post: post}),
    do: ReturnPath.sign_in_path(~p"/feedback/#{post.slug}")

  defp sign_in_href(%{return_to: return_to}), do: ReturnPath.sign_in_path(return_to)

  defp post_by_slug(slug) when is_binary(slug) do
    result =
      Post
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.filter(slug == ^slug)
      |> Ash.read_one(actor: nil)

    case result do
      {:ok, %Post{} = post} -> post
      _missing -> nil
    end
  end

  # The island degrades to nothing rather than crash if the caller
  # contract ever drifts (see VoteIsland's twin).
  # coveralls-ignore-next-line
  defp post_by_slug(_missing), do: nil

  defp comment_count(post), do: Ash.get!(Post, post.id, actor: nil).comment_count

  defp comments_label(count), do: FluxValeWeb.FeedbackHTML.comments_label(count)
end
