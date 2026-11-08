defmodule FluxValeWeb.AdminLive.Moderation do
  @moduledoc """
  The admin feedback moderation surface (#501, [ADR-0026](../../../../../docs/adr/00026-feedback-board.md)
  Am. 1's purpose-built successor, ADR-0027 Am. 4's sidebar shell): the
  board's posts as a capped, filtered list, each expanding in place to
  the sanitized body, its comments, its votes, and its tags, with the
  moderation writes the domain's own policies already gate — post
  destroy, vote retract, comment delete, and the tag vocabulary's CRUD.

  Every read and write rides the feedback domain with the
  platform-admin actor and `authorize?: true` — the domain policies
  decide, never the UI. No `authorize?: false` anywhere on this
  surface.

  The honest-consequence grammar: each destructive write reveals an
  inline confirm naming what it takes with it BEFORE anything happens,
  and the pre-submit probes name what the domain will refuse — a
  referenced original says so before the operator commits, while the
  guard itself stays in the action (`Post.RejectReferencedOriginal`).
  Bodies never render raw: the post body rides `Feedback.Markdown`
  (#488, the board's own sanitized renderer), comment bodies ride the
  `body_html` calculation — the same sanitizer, computed at read.
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Feedback.Comment
  alias FluxVale.Feedback.Markdown
  alias FluxVale.Feedback.Post
  alias FluxVale.Feedback.Tag
  alias FluxVale.Feedback.Vote
  alias FluxValeWeb.AdminComponents
  alias FluxValeWeb.AdminShell
  alias FluxValeWeb.FeedbackHTML

  require Ash.Query

  # The list cap (the people surface's ruling, same shape): an
  # unbounded read over user-generated rows is an ilike scan plus an
  # unindexed sort waiting to grow expensive, and the operator scans
  # for what just landed anyway. Revisit trigger: pagination once post
  # volume approaches the cap.
  @list_cap 100

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    # The chrome assigns (current_user, username, nav_section) ride the
    # AdminChrome on_mount on the :admin live_session — this mount adds
    # only the page's own data.
    admin = socket.assigns.current_user

    {:ok,
     socket
     |> assign(
       query: "",
       status: nil,
       statuses: Post.status_values(),
       expanded_id: nil,
       detail: nil,
       confirm: nil,
       tag_rename_id: nil,
       tag_rename_form: nil,
       tag_rename_tag: nil,
       search_form: to_form(%{"query" => ""}, as: :search),
       tag_form: build_tag_form(admin)
     )
     |> refresh_rows()
     |> refresh_tags()}
  end

  # -- events ---------------------------------------------------------------

  @impl Phoenix.LiveView
  def handle_event("search", %{"search" => %{"query" => query}}, socket)
      when is_binary(query) do
    trimmed = String.trim(query)

    {:noreply,
     socket
     |> assign(
       query: trimmed,
       search_form: to_form(%{"query" => trimmed}, as: :search),
       # The list moves under a reset, so an open expansion and confirm
       # close with it (the people surface's rule).
       expanded_id: nil,
       detail: nil,
       confirm: nil
     )
     |> refresh_rows()}
  end

  # A crafted query that is not a string is a no-op, not a crash.
  def handle_event("search", _params, socket), do: {:noreply, socket}

  # All: the chip clears the status filter. Known statuses narrow to
  # it. Anything else (a crafted value) leaves the filter alone.
  def handle_event("filter-status", %{"status" => ""}, socket) do
    {:noreply,
     socket
     |> assign(status: nil, expanded_id: nil, detail: nil, confirm: nil)
     |> refresh_rows()}
  end

  def handle_event("filter-status", %{"status" => raw}, socket) do
    case parse_status(raw) do
      nil ->
        {:noreply, socket}

      status ->
        {:noreply,
         socket
         |> assign(status: status, expanded_id: nil, detail: nil, confirm: nil)
         |> refresh_rows()}
    end
  end

  # The expansion toggle. The open is a fresh domain read (the people
  # reveal posture): a post deleted between the list render and the
  # click never opens a panel. The stream RESET re-renders every row
  # from the new assigns, so an earlier expansion collapses — a lone
  # stream_insert would leave the previous panel on its row and grow a
  # second expansion (the stale-panel defect class, pinned by test).
  def handle_event("open-post", %{"id" => id}, socket) do
    if socket.assigns.expanded_id == id do
      {:noreply,
       socket
       |> close_expansion()
       |> refresh_rows()}
    else
      admin = socket.assigns.current_user

      case load_detail(id, admin) do
        {:ok, detail} ->
          {:noreply,
           socket
           |> assign(expanded_id: id, detail: detail, confirm: nil)
           |> refresh_rows()}

        {:error, _gone} ->
          {:noreply,
           socket
           |> put_flash(:error, gone_copy())
           |> refresh_all()}
      end
    end
  end

  # The day-one click's reveal. The probe mirrors the action's guard
  # (RejectReferencedOriginal): a referenced original shows the honest
  # note INSTEAD of a confirm — the guard itself stays in the action,
  # so a duplicate planted after the probe still refuses the write. A
  # frame naming a post whose panel is not open is stale or crafted;
  # the honest answer is the same refresh. Every reveal re-streams its
  # row, because stream items do not re-render on assign changes.
  def handle_event("open-destroy-post", %{"id" => id}, socket) do
    admin = socket.assigns.current_user

    case Ash.get(Post, id, actor: admin, authorize?: true, load: :created_by_user) do
      {:ok, post} ->
        if stale_frame?(socket, id) do
          {:noreply,
           socket
           |> put_flash(:error, stale_copy())
           |> close_expansion()
           |> refresh_all()}
        else
          reveal_destroy_probe(post, socket)
        end

      {:error, _gone} ->
        {:noreply,
         socket
         |> put_flash(:error, gone_copy())
         |> close_expansion()
         |> refresh_all()}
    end
  end

  # The destructive click. The record is re-read fresh, so a raced
  # delete answers here; the referenced guard stays in the action and
  # its refusal is the honest flash below.
  @impl Phoenix.LiveView
  def handle_event("confirm-destroy-post", _params, socket) do
    case socket.assigns.confirm do
      %{kind: :post, id: id} -> do_destroy_post(id, socket)
      _none -> {:noreply, socket}
    end
  end

  def handle_event("open-retract-vote", %{"id" => id}, socket) do
    admin = socket.assigns.current_user

    case Ash.get(Vote, id, actor: admin, authorize?: true) do
      {:ok, vote} ->
        confirm_held_vote(vote, socket)

      {:error, _gone} ->
        {:noreply,
         socket
         |> put_flash(:error, gone_copy())
         |> refresh_all()}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("confirm-retract-vote", _params, socket) do
    case socket.assigns.confirm do
      %{kind: :vote, id: id} -> do_retract_vote(id, socket)
      _none -> {:noreply, socket}
    end
  end

  def handle_event("open-delete-comment", %{"id" => id}, socket) do
    admin = socket.assigns.current_user

    case Ash.get(Comment, id, actor: admin, authorize?: true) do
      {:ok, comment} ->
        confirm_held_comment(comment, socket)

      {:error, _gone} ->
        {:noreply,
         socket
         |> put_flash(:error, gone_copy())
         |> refresh_all()}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("confirm-delete-comment", _params, socket) do
    case socket.assigns.confirm do
      %{kind: :comment, id: id} -> do_delete_comment(id, socket)
      _none -> {:noreply, socket}
    end
  end

  # The tag delete lever. A used tag opens the confirm naming the untag
  # consequence; an UNUSED tag has no destructive consequence, so it
  # deletes outright — no ceremony (the judged grammar).
  def handle_event("open-delete-tag", %{"id" => id}, socket) do
    admin = socket.assigns.current_user

    case Ash.get(Tag, id, actor: admin, authorize?: true, load: :post_tags) do
      {:ok, tag} ->
        open_delete_tag(tag, admin, socket)

      {:error, _gone} ->
        {:noreply,
         socket
         |> put_flash(:error, gone_copy())
         |> refresh_all()}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("confirm-delete-tag", _params, socket) do
    case socket.assigns.confirm do
      %{kind: :tag, id: id} -> do_delete_tag(id, socket)
      _none -> {:noreply, socket}
    end
  end

  def handle_event("validate-tag", %{"tag" => params}, socket) when is_map(params) do
    # The create form exists from mount to teardown (every failure path
    # rebuilds it), so there is no nil form to guard here — unlike the
    # rename pair, whose form only exists while a rename is open.
    form = AshPhoenix.Form.validate(socket.assigns.tag_form, normalize_tag_params(params))

    {:noreply, assign(socket, tag_form: form)}
  end

  def handle_event("validate-tag", _params, socket), do: {:noreply, socket}

  def handle_event("create-tag", %{"tag" => params}, socket) when is_map(params) do
    admin = socket.assigns.current_user
    params = normalize_tag_params(params)
    form = AshPhoenix.Form.validate(socket.assigns.tag_form, params)

    case AshPhoenix.Form.submit(form, params: params) do
      {:ok, _tag} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Tag created."))
         |> assign(tag_form: build_tag_form(admin))
         |> refresh_tags()}

      {:error, error_form} ->
        {:noreply, assign(socket, tag_form: to_form(error_form))}
    end
  end

  def handle_event("create-tag", _params, socket), do: {:noreply, socket}

  def handle_event("open-rename-tag", %{"id" => id}, socket) do
    admin = socket.assigns.current_user

    case Ash.get(Tag, id, actor: admin, authorize?: true, load: :post_tags) do
      {:ok, tag} ->
        form =
          tag
          |> AshPhoenix.Form.for_update(:update, as: "tag_rename", actor: admin, authorize?: true)
          |> to_form()

        {:noreply,
         socket
         |> assign(tag_rename_id: tag.id, tag_rename_form: form, tag_rename_tag: tag)
         |> refresh_tags()}

      {:error, _gone} ->
        {:noreply,
         socket
         |> put_flash(:error, gone_copy())
         |> refresh_tags()}
    end
  end

  def handle_event("validate-tag-rename", %{"tag_rename" => params}, socket)
      when is_map(params) do
    case socket.assigns.tag_rename_form do
      nil ->
        # A crafted keystroke with no rename open is a no-op.
        {:noreply, socket}

      form ->
        params = Map.put(params, "name", trimmed(params["name"]))
        form = AshPhoenix.Form.validate(form, params)

        {:noreply, assign(socket, tag_rename_form: form)}
    end
  end

  def handle_event("validate-tag-rename", _params, socket), do: {:noreply, socket}

  def handle_event("save-tag-rename", %{"tag_rename" => params}, socket)
      when is_map(params) do
    case socket.assigns.tag_rename_form do
      nil ->
        {:noreply, socket}

      form ->
        params = Map.put(params, "name", trimmed(params["name"]))
        form = AshPhoenix.Form.validate(form, params)

        case AshPhoenix.Form.submit(form, params: params) do
          {:ok, _tag} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Tag renamed."))
             |> assign(tag_rename_id: nil, tag_rename_form: nil, tag_rename_tag: nil)
             |> refresh_tags()}

          {:error, error_form} ->
            {:noreply, assign(socket, tag_rename_form: to_form(error_form))}
        end
    end
  end

  def handle_event("save-tag-rename", _params, socket), do: {:noreply, socket}

  def handle_event("cancel-rename-tag", _params, socket) do
    # The reset re-renders every tag row, so the open form actually
    # leaves the DOM (the stale-panel rule, pinned by test).
    {:noreply,
     socket
     |> assign(tag_rename_id: nil, tag_rename_form: nil, tag_rename_tag: nil)
     |> refresh_tags()}
  end

  # One cancel for every confirm panel (the single confirm slot makes
  # the shared handler safe). The refresh re-streams the owning rows,
  # so the open panel actually leaves the DOM.
  @impl Phoenix.LiveView
  def handle_event("cancel-confirm", _params, socket) do
    {:noreply, refresh_all(assign(socket, confirm: nil))}
  end

  # -- writes ----------------------------------------------------------------

  # A vote the open panel does not hold (a crafted or stale frame) gets
  # the quiet expired arm, consistent with the destroy reveal's guard.
  defp confirm_held_vote(vote, socket) do
    detail = socket.assigns.detail

    if is_nil(detail) or not Enum.any?(detail.votes, &(&1.id == vote.id)) do
      {:noreply,
       socket
       |> put_flash(:error, stale_copy())
       |> close_expansion()
       |> refresh_all()}
    else
      {:noreply,
       socket
       |> assign(confirm: %{kind: :vote, id: vote.id})
       |> refresh_rows()}
    end
  end

  # The comment twin of the retract reveal's guard.
  defp confirm_held_comment(comment, socket) do
    detail = socket.assigns.detail

    if is_nil(detail) or not Enum.any?(detail.comments, &(&1.id == comment.id)) do
      {:noreply,
       socket
       |> put_flash(:error, stale_copy())
       |> close_expansion()
       |> refresh_all()}
    else
      {:noreply,
       socket
       |> assign(confirm: %{kind: :comment, id: comment.id})
       |> refresh_rows()}
    end
  end

  defp reveal_destroy_probe(post, socket) do
    admin = socket.assigns.current_user
    count = referenced_count(post.id, admin)

    if count > 0 do
      detail = %{socket.assigns.detail | referenced_count: count}

      {:noreply,
       socket
       |> assign(detail: detail, confirm: nil)
       |> refresh_rows()}
    else
      {:noreply,
       socket
       |> assign(confirm: %{kind: :post, id: post.id})
       |> refresh_rows()}
    end
  end

  defp open_delete_tag(tag, _admin, socket) do
    usage = length(tag.post_tags)

    if usage > 0 do
      confirm = %{kind: :tag, id: tag.id, name: tag.name, usage: usage}

      {:noreply,
       socket
       |> assign(confirm: confirm)
       |> refresh_tags()}
    else
      admin = socket.assigns.current_user
      delete_unused_tag(tag, admin, socket)
    end
  end

  defp delete_unused_tag(tag, admin, socket) do
    case destroy_tag(tag, admin) do
      :ok ->
        {:noreply, tag_deleted(socket)}

      # coveralls-ignore-start - tag destroy has no gate behind the
      # fresh-read admin actor: no validations, no counter maintenance,
      # no stale filter. The refusal arm is the DB-error class, which
      # ExUnit cannot simulate.
      {:error, _refused} ->
        {:noreply, refused_refresh(socket)}

        # coveralls-ignore-stop
    end
  end

  defp do_destroy_post(id, socket) do
    admin = socket.assigns.current_user

    case Ash.get(Post, id, actor: admin, authorize?: true) do
      {:ok, post} ->
        case Ash.destroy(post, actor: admin, authorize?: true) do
          {:error, error} ->
            {:noreply, destroy_refused(socket, error)}

          _deleted ->
            {:noreply,
             socket
             |> put_flash(
               :info,
               gettext("Post deleted. Its votes and comments were removed with it.")
             )
             |> close_expansion()
             |> refresh_all()}
        end

      {:error, error} ->
        {:noreply, destroy_refused(socket, error)}
    end
  end

  defp do_retract_vote(id, socket) do
    admin = socket.assigns.current_user

    case Ash.get(Vote, id, actor: admin, authorize?: true) do
      {:ok, vote} ->
        case Vote.retract(vote, actor: admin) do
          :ok ->
            {:noreply,
             socket
             |> put_flash(
               :info,
               gettext("Vote removed. The post's vote count dropped by one.")
             )
             |> assign(confirm: nil)
             |> refresh_all()}

          {:error, _refused} ->
            {:noreply, refused_refresh(socket)}
        end

      {:error, _gone} ->
        {:noreply, refused_refresh(socket)}
    end
  end

  defp do_delete_comment(id, socket) do
    admin = socket.assigns.current_user

    case Ash.get(Comment, id, actor: admin, authorize?: true) do
      {:ok, comment} ->
        case Ash.destroy(comment, actor: admin, authorize?: true) do
          {:error, _refused} ->
            {:noreply, refused_refresh(socket)}

          _deleted ->
            {:noreply,
             socket
             |> put_flash(
               :info,
               gettext("Comment removed. The post's comment count dropped by one.")
             )
             |> assign(confirm: nil)
             |> refresh_all()}
        end

      {:error, _gone} ->
        {:noreply, refused_refresh(socket)}
    end
  end

  # The confirm's click re-reads the tag WITH its pairings: the
  # reveal's count can go stale while the panel is up (another admin
  # tagging or untagging), so the destructive action rides the truth at
  # the moment of the write. The consequence the panel named either
  # still holds or has dissolved to nothing — both answers are the
  # delete the operator asked for, and the refresh makes the list say
  # so.
  defp do_delete_tag(id, socket) do
    admin = socket.assigns.current_user

    case Ash.get(Tag, id, actor: admin, authorize?: true, load: :post_tags) do
      {:ok, tag} ->
        case destroy_tag(tag, admin) do
          :ok ->
            {:noreply, tag_deleted(socket)}

          # coveralls-ignore-start - the same no-gate posture as
          # delete_unused_tag: the DB-error class.
          {:error, _refused} ->
            {:noreply, refused_refresh(socket)}

            # coveralls-ignore-stop
        end

      {:error, _gone} ->
        {:noreply, refused_refresh(socket)}
    end
  end

  defp destroy_tag(tag, admin) do
    case Ash.destroy(tag, actor: admin, authorize?: true) do
      # coveralls-ignore-start - no deterministic refusal exists for a
      # freshly-read tag under an admin actor; the arm is defensive
      # totality over the DB-error class.
      {:error, _refused} ->
        {:error, :refused}

      # coveralls-ignore-stop
      _deleted ->
        :ok
    end
  end

  # The refusal reads the action's own answer: a duplicate planted
  # between the reveal and the click names itself, everything else is
  # one honest line and a refresh.
  defp destroy_refused(socket, error) do
    message =
      if referenced_refusal?(error) do
        gettext(
          "The delete was refused. A duplicate now points at this post. The list is refreshed."
        )
      else
        gettext("The delete was refused. The post moved before the click. The list is refreshed.")
      end

    socket
    |> put_flash(:error, message)
    |> assign(confirm: nil)
    |> close_expansion()
    |> refresh_all()
  end

  # The classifier behind the destroy refusal, public for the test that
  # pins each error class. The in-transaction probe answers the
  # ordinary race (Invalid with the guard's field-scoped error); the
  # TRULY-concurrent race — a duplicate inserted between the probe read
  # and the DELETE — loses at the duplicate_of FK, which Ash wraps as
  # Unknown-class. Both name the duplicate; everything else (NotFound,
  # the DB-down class) reads the generic line.
  @doc false
  @spec referenced_refusal?(term()) :: boolean()
  def referenced_refusal?(%Ash.Error.Invalid{errors: errors}) do
    Enum.any?(errors, &duplicate_ref?/1)
  end

  def referenced_refusal?(%Ash.Error.Unknown{errors: errors}) do
    Enum.any?(errors, &duplicate_ref?/1)
  end

  # coveralls-ignore-next-line - a refusal that is neither class is the
  # DB-down class, which ExUnit cannot simulate; the generic flash is
  # the honest answer there.
  def referenced_refusal?(_other), do: false

  defp duplicate_ref?(%{field: :duplicate_of_id}), do: true
  defp duplicate_ref?(_other), do: false

  defp refused_refresh(socket) do
    socket
    |> put_flash(
      :error,
      gettext("That change was refused. The item moved before the click. The list is refreshed.")
    )
    |> assign(confirm: nil)
    |> refresh_all()
  end

  defp tag_deleted(socket) do
    socket
    |> put_flash(:info, gettext("Tag deleted."))
    |> assign(confirm: nil)
    |> refresh_all()
  end

  defp gone_copy do
    gettext("That item is gone from the board. The list is refreshed.")
  end

  defp stale_copy do
    gettext("That panel is no longer open. The list is refreshed.")
  end

  # The reveal handlers answer frames the rendered page cannot send:
  # the post's panel not open, or open for a different post.
  defp stale_frame?(socket, id) do
    detail = socket.assigns.detail
    is_nil(detail) or detail.post.id != id
  end

  # -- reads -----------------------------------------------------------------

  # Newest first, capped one past the limit (the over-read answers the
  # capped? question without a count), filtered by the status chips and
  # the title-or-author search. Both scopes stay inside this list.
  defp refresh_rows(socket) do
    admin = socket.assigns.current_user

    fetched =
      Post
      |> Ash.Query.for_read(:read, %{}, actor: admin)
      |> Ash.Query.sort(created_at: :desc)
      |> maybe_search(socket.assigns.query)
      |> maybe_status(socket.assigns.status)
      |> Ash.Query.limit(@list_cap + 1)
      |> Ash.Query.load(:created_by_user)
      |> Ash.read!()

    capped? = length(fetched) > @list_cap
    posts = Enum.take(fetched, @list_cap)

    socket
    |> assign(rows_empty?: posts == [], rows_capped?: capped?)
    |> stream(:posts, posts, reset: true)
  end

  defp maybe_search(query, ""), do: query

  defp maybe_search(query, term) do
    pattern = "%#{term}%"

    Ash.Query.filter(
      query,
      ilike(title, ^pattern) or exists(created_by_user, ilike(username, ^pattern))
    )
  end

  defp maybe_status(query, nil), do: query

  defp maybe_status(query, status) do
    Ash.Query.filter(query, status == ^status)
  end

  # Declared atoms only, matched by string — no input path ever builds
  # an atom (the board controller's rule).
  defp parse_status(raw) when is_binary(raw) do
    Enum.find(Post.status_values(), fn status -> Atom.to_string(status) == raw end)
  end

  defp parse_status(_other), do: nil

  defp refresh_tags(socket) do
    admin = socket.assigns.current_user

    tags =
      Tag
      |> Ash.Query.for_read(:read, %{}, actor: admin)
      |> Ash.Query.sort(name: :asc)
      |> Ash.Query.load(:post_tags)
      |> Ash.read!()

    socket
    |> assign(tags_empty?: tags == [])
    |> stream(:tags, tags, reset: true)
  end

  # The expansion's whole truth, one read set: the post with its tags
  # and author, the sanitized body (the board's renderer — never raw),
  # the comments with their sanitized HTML, the votes with their
  # casters, and the reference probe the destroy reveal prints.
  defp load_detail(post_id, admin) do
    case Ash.get(Post, post_id, actor: admin, authorize?: true, load: [:tags, :created_by_user]) do
      {:ok, post} ->
        comments =
          Comment
          |> Ash.Query.for_read(:read, %{}, actor: admin)
          |> Ash.Query.filter(post_id == ^post.id)
          |> Ash.Query.sort(created_at: :desc)
          |> Ash.Query.load([:author_username, :body_html])
          |> Ash.read!(actor: admin)

        votes =
          Vote
          |> Ash.Query.for_read(:read, %{}, actor: admin)
          |> Ash.Query.filter(post_id == ^post.id)
          |> Ash.Query.sort(created_at: :desc)
          |> Ash.Query.load(:cast_by_user)
          |> Ash.read!(actor: admin)

        {:ok,
         %{
           post: post,
           description_html: Markdown.render(post.description),
           comments: comments,
           votes: votes,
           referenced_count: referenced_count(post.id, admin)
         }}

      {:error, _gone} ->
        {:error, :gone}
    end
  end

  defp referenced_count(post_id, admin) do
    Post
    |> Ash.Query.for_read(:read, %{}, actor: admin)
    |> Ash.Query.filter(duplicate_of_id == ^post_id)
    |> Ash.count!(actor: admin)
  end

  # -- state helpers ---------------------------------------------------------

  # Closing is an assign change only: every caller re-renders the list
  # right after (refresh_rows or refresh_all), because stream items do
  # not re-render on assign changes.
  defp close_expansion(socket) do
    assign(socket, expanded_id: nil, detail: nil, confirm: nil)
  end

  # Every write lands here: the list, the vocabulary, and any open
  # expansion re-read together, so the page never contradicts the
  # domain.
  defp refresh_all(socket) do
    socket
    |> refresh_rows()
    |> refresh_tags()
    |> refresh_expanded()
  end

  defp refresh_expanded(socket) do
    case socket.assigns.expanded_id do
      nil ->
        socket

      id ->
        admin = socket.assigns.current_user

        case load_detail(id, admin) do
          {:ok, detail} ->
            socket
            |> assign(detail: detail)
            |> stream_insert(:posts, detail.post)

          # coveralls-ignore-start - the expanded post cannot vanish
          # between refresh_rows and this re-read in the same tick;
          # another process deleting it mid-write is the DB-down class,
          # which ExUnit cannot simulate.
          {:error, _gone} ->
            assign(socket, expanded_id: nil, detail: nil, confirm: nil)

            # coveralls-ignore-stop
        end
    end
  end

  defp build_tag_form(admin) do
    Tag
    |> AshPhoenix.Form.for_create(:create, as: "tag", actor: admin, authorize?: true)
    |> to_form()
  end

  # The slug field is optional: a blank input must reach the action as
  # nil, or DeriveSlug never runs and the blank string fails the slug
  # constraint instead.
  defp normalize_tag_params(params) do
    params
    |> Map.put("name", trimmed(params["name"]))
    |> Map.put("slug", blank_to_nil(params["slug"]))
  end

  defp trimmed(nil), do: ""
  defp trimmed(value), do: String.trim(value)

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: String.trim(value)

  # -- display helpers -------------------------------------------------------

  # The author cell's honest fallback: system-created posts carry no
  # author (SetActorDefaults stamps none without an actor).
  defp author_label(%{created_by_user: %{username: username}}) when is_binary(username) do
    username
  end

  defp author_label(%{created_by_user: nil}), do: nil

  # The vote's caster, nil-safe: the demo seed casts ownerless votes on
  # purpose (cast_demo_vote! has no actor), so ownerless rows are a
  # normal state of a seeded board and read as unknown, not a crash.
  defp caster_label(%{cast_by_user: %{username: username}}) when is_binary(username) do
    username
  end

  defp caster_label(_ownerless), do: gettext("Unknown caster")

  # The expansion's age line WITHOUT doubling the status word: the
  # badge beside it already says the status, so this carries only the
  # age ("10 minutes ago"), falling back to the posted age for a post
  # that never moved.
  defp status_age_line(%{status_changed_at: %DateTime{} = at}), do: time_ago(at)

  defp status_age_line(post) do
    gettext("posted %{ago}", ago: time_ago(post.created_at))
  end

  # The non-color shape cue for the tone-collision pairs (the 583
  # icon-on-Expired grammar): Started and Planned share the amber tone,
  # Open and Duplicate share the neutral one, so each carries its own
  # icon in either theme. Completed and Declined own their tones alone
  # and rest uncued.
  defp status_cue(:planned), do: "hero-calendar-days"
  defp status_cue(:started), do: "hero-arrow-path"
  defp status_cue(:open), do: "hero-flag"
  defp status_cue(:duplicate), do: "hero-link"
  defp status_cue(_completed_or_declined), do: nil

  defp stamp_text(stamp), do: Calendar.strftime(stamp, "%b %d, %Y")

  defp time_ago(datetime), do: FeedbackHTML.time_ago(datetime)

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
      wide
    >
      <%!-- The console lane (#593): `wide` chrome + `appgram console`
      - flush sidebar, the surface fills the space beside it. --%>
      <div class="appgram console contents" data-testid="admin-moderation">
        <section class="band">
          <div class="wrap pt-8 pb-10">
            <div class="rise">
              <p class="eyebrow">{gettext("Operator console")}</p>
              <h1 class="page-title mt-1.5">{gettext("Feedback moderation")}</h1>
              <p class="mt-2 max-w-prose text-base text-ink-muted">
                {gettext(
                  "The board's posts with their votes, comments, and tags. Every delete names what it takes with it before anything happens."
                )}
              </p>
              <div class="mt-4">
                <.link
                  href={~p"/feedback"}
                  data-testid="admin-moderation-board-link"
                  class="text-sm font-medium text-link underline-offset-2 hover:underline"
                >
                  {gettext("Open the public board")}
                </.link>
              </div>
            </div>
          </div>
        </section>

        <%!-- The section sidebar (Am. 4, the #568 idiom) owns
        cross-section wayfinding; the board link stays — it is the
        section's subject, not navigation. --%>
        <section class="wrap pt-8 pb-16">
          <div class="rise flex flex-col gap-8 md:flex-row md:gap-12">
            <AdminShell.sidebar current="feedback" />

            <div class="min-w-0 flex-1 space-y-6" data-testid="admin-moderation-content">
              <%!-- The toolbar: the search and the status filter. The
              status vocabulary is worth filtering by (it IS the board's
              workflow), so the filter chips ride beside the search —
              the same chips the public board renders. The search field
              sits carded (the 571 shape). --%>
              <div class="space-y-4" data-testid="admin-moderation-toolbar">
                <.card class="space-y-4" data-testid="admin-moderation-search-card">
                  <div>
                    <h2 class="text-base font-medium text-ink">{gettext("Find posts")}</h2>
                    <p class="mt-1 text-sm text-ink-muted">
                      {gettext("Search by title or author. It never reaches past this list.")}
                    </p>
                  </div>
                  <.form
                    for={@search_form}
                    id="admin-moderation-search"
                    phx-change="search"
                    phx-submit="search"
                  >
                    <.input
                      field={@search_form[:query]}
                      type="text"
                      label={gettext("Search")}
                      placeholder={gettext("Search by title or author")}
                      phx-debounce="200"
                      data-testid="admin-moderation-search-input"
                    />
                  </.form>
                </.card>

                <div
                  class="flex flex-wrap items-center gap-2"
                  role="group"
                  aria-label={gettext("Filter by status")}
                  data-testid="admin-moderation-status-filter"
                >
                  <button
                    type="button"
                    phx-click="filter-status"
                    phx-value-status=""
                    aria-pressed={is_nil(@status)}
                    class={[
                      "rounded-full border px-3 py-1 text-xs font-medium motion-safe:transition-colors motion-safe:duration-(--motion-fast)",
                      is_nil(@status) && "border-primary/25 bg-primary-muted text-link",
                      not is_nil(@status) && "border-line bg-panel text-ink-muted hover:text-ink"
                    ]}
                    data-testid="admin-moderation-filter-all"
                  >
                    {gettext("All")}
                  </button>
                  <button
                    :for={status <- @statuses}
                    type="button"
                    phx-click="filter-status"
                    phx-value-status={Atom.to_string(status)}
                    aria-pressed={@status == status}
                    class={[
                      "rounded-full border px-3 py-1 text-xs font-medium motion-safe:transition-colors motion-safe:duration-(--motion-fast)",
                      @status == status && "border-primary/25 bg-primary-muted text-link",
                      @status != status && "border-line bg-panel text-ink-muted hover:text-ink"
                    ]}
                    data-testid={"admin-moderation-filter-#{status}"}
                  >
                    {FeedbackHTML.status_label(status)}
                  </button>
                </div>
              </div>

              <div class="space-y-4" data-testid="admin-moderation-list">
                <%!-- The count is the @list_cap above (kept literal here —
                a module attribute reads as assigns inside HEEx); move the
                two together. --%>
                <p
                  :if={@rows_capped?}
                  class="text-sm text-ink-muted"
                  data-testid="admin-moderation-capped"
                >
                  {gettext("Showing the latest 100 posts.")}
                </p>

                <%!-- The empty states ride the inset shape (571's): inside
                the list panel, not a bare dashed box. --%>
                <div
                  :if={@rows_empty?}
                  class="rounded-panel border border-line bg-panel px-6 py-8"
                  data-testid="admin-moderation-empty"
                >
                  <.empty_state
                    :if={@query == "" and is_nil(@status)}
                    title={gettext("No posts on the board yet.")}
                    class="border-none bg-transparent"
                  >
                    {gettext("Posts land here as the community files them.")}
                  </.empty_state>

                  <.empty_state
                    :if={@query != "" or not is_nil(@status)}
                    title={gettext("No post matches that search or filter.")}
                    class="border-none bg-transparent"
                  />
                </div>

                <div :if={not @rows_empty?} class="rounded-panel border border-line bg-panel text-ink">
                  <%!-- One grid template shared by the header and every row
                  (kept literal in both spots), so the columns can never
                  drift. Track mins total about 24rem, so the populated
                  list fits the band beside the sidebar at 1024+ with no
                  horizontal scroll and no min-width floor. --%>
                  <div class={[
                    "grid-cols-[minmax(0,1fr)_5rem_3rem_4.5rem_5rem_4.25rem]",
                    AdminComponents.admin_table_header_class()
                  ]}>
                    <div>{gettext("Post")}</div>
                    <div>{gettext("Status")}</div>
                    <div>{gettext("Votes")}</div>
                    <div>{gettext("Comments")}</div>
                    <div>{gettext("Posted")}</div>
                    <div class="sr-only">{gettext("Actions")}</div>
                  </div>

                  <%!-- The separator rides this stream wrapper. The grid
                  inside stays pure shared chrome (#602). --%>
                  <div id="admin-moderation-posts" phx-update="stream">
                    <div
                      :for={{dom_id, post} <- @streams.posts}
                      id={dom_id}
                      class="border-b border-line last:border-0"
                    >
                      <div class={[
                        "grid-cols-[minmax(0,1fr)_5rem_3rem_4.5rem_5rem_4.25rem]",
                        AdminComponents.admin_table_row_class()
                      ]}>
                        <div class="min-w-0">
                          <p
                            class="text-sm font-medium text-ink [overflow-wrap:anywhere]"
                            data-testid={"admin-moderation-title-#{post.id}"}
                          >
                            {post.title}
                          </p>
                          <p
                            class="mt-0.5 truncate text-xs text-ink-muted"
                            data-testid={"admin-moderation-author-#{post.id}"}
                          >
                            {author_label(post)}
                          </p>
                        </div>
                        <div>
                          <span data-testid={"admin-moderation-status-#{post.id}"}>
                            <.badge
                              tone={FeedbackHTML.status_tone(post.status)}
                              class="gap-1 px-1.5! text-[11px]!"
                            >
                              <%= if cue = status_cue(post.status) do %>
                                <.icon name={cue} class="size-3" />
                              <% end %>
                              {FeedbackHTML.status_label(post.status)}
                            </.badge>
                          </span>
                        </div>
                        <div>
                          <span
                            class="text-sm text-ink-muted"
                            data-testid={"admin-moderation-votes-#{post.id}"}
                          >
                            {post.vote_count}
                          </span>
                        </div>
                        <div>
                          <span
                            class="text-sm text-ink-muted"
                            data-testid={"admin-moderation-comments-#{post.id}"}
                          >
                            {post.comment_count}
                          </span>
                        </div>
                        <div>
                          <span
                            class="whitespace-nowrap text-xs text-ink-muted"
                            data-testid={"admin-moderation-posted-#{post.id}"}
                          >
                            {stamp_text(post.created_at)}
                          </span>
                        </div>
                        <div>
                          <div class="flex items-center justify-end">
                            <.button
                              size="sm"
                              variant="secondary"
                              phx-click="open-post"
                              phx-value-id={post.id}
                              phx-disable-with={gettext("Opening...")}
                              data-testid={"admin-moderation-expand-#{post.id}"}
                            >
                              <%= if @expanded_id == post.id do %>
                                {gettext("Close")}
                              <% else %>
                                {gettext("Expand")}
                              <% end %>
                            </.button>
                          </div>
                        </div>
                      </div>

                      <%!-- The expansion under its row (the people confirm's
                      posture): one open at a time, opened through a fresh
                      domain read, re-rendered with its row. --%>
                      <div
                        :if={@expanded_id == post.id && @detail}
                        id={"admin-moderation-detail-#{post.id}"}
                        class="space-y-5 border-t border-line px-4 pb-4 pt-4"
                        data-testid={"admin-moderation-detail-#{post.id}"}
                      >
                        <div class="flex flex-wrap items-center gap-x-3 gap-y-1 text-sm text-ink-muted">
                          <.badge tone={FeedbackHTML.status_tone(@detail.post.status)} class="gap-1">
                            <%= if cue = status_cue(@detail.post.status) do %>
                              <.icon name={cue} class="size-3.5" />
                            <% end %>
                            {FeedbackHTML.status_label(@detail.post.status)}
                          </.badge>
                          <span>{status_age_line(@detail.post)}</span>
                        </div>

                        <div
                          :if={@detail.post.tags != []}
                          class="flex flex-wrap items-center gap-2"
                          data-testid="admin-moderation-post-tags"
                        >
                          <span class="text-xs font-medium tracking-wide text-ink-muted uppercase">
                            {gettext("Tags")}
                          </span>
                          <span
                            :for={tag <- @detail.post.tags}
                            data-testid={"admin-moderation-post-tag-#{tag.slug}"}
                            class="rounded-full border border-line bg-panel px-2 py-0.5 text-xs font-medium text-ink-muted"
                          >
                            {tag.name}
                          </span>
                        </div>

                        <%!-- The body rides Feedback.Markdown (#488), the
                        board's own sanitized renderer — the same posture
                        as the public post page, never a raw body. The
                        measure stays a read surface's: about 65
                        characters at 14px. --%>
                        <div
                          data-testid="admin-moderation-post-body"
                          class="feedback-body max-w-[65ch] text-sm leading-relaxed text-ink [overflow-wrap:anywhere]"
                        >
                          {raw(@detail.description_html)}
                        </div>

                        <%!-- The moderation levers share one destructive
                        slot (@confirm), so the confirm_block contract's
                        one-confirm-per-panel holds on this page too. The
                        heavy danger grammar is the post destroy's alone:
                        the vote's inline confirm stays light (571's
                        color grammar), and a referenced original's
                        delete button disables WITH its reason rather
                        than offering a click the action will refuse. --%>
                        <div class="space-y-3" data-testid="admin-moderation-danger-zone">
                          <.callout
                            :if={@detail.referenced_count > 0}
                            tone="warning"
                            title={
                              ngettext(
                                "1 duplicate points at this post",
                                "%{count} duplicates point at this post",
                                @detail.referenced_count
                              )
                            }
                            data-testid="admin-moderation-referenced-note"
                          >
                            <p>
                              {gettext(
                                "This original refuses deletion while a duplicate points at it. Delete the duplicate first, then delete this one."
                              )}
                            </p>
                          </.callout>

                          <div class="flex justify-end">
                            <.button
                              size="sm"
                              variant="destructive"
                              disabled={@detail.referenced_count > 0}
                              phx-click="open-destroy-post"
                              phx-value-id={@detail.post.id}
                              phx-disable-with={gettext("Opening...")}
                              data-testid="admin-moderation-destroy-post"
                            >
                              {gettext("Delete post")}
                            </.button>
                          </div>

                          <div :if={@confirm && @confirm.kind == :post}>
                            <.confirm_block
                              title={gettext("Delete this post?")}
                              body={
                                gettext(
                                  "The post leaves the board. Its votes and comments are removed with it. This cannot be undone."
                                )
                              }
                              action={gettext("Yes, delete this post")}
                              event="confirm-destroy-post"
                              action_testid="admin-moderation-destroy-confirm"
                              cancel_testid="admin-moderation-destroy-cancel"
                              return_focus="[data-testid='admin-moderation-destroy-post']"
                              myself={nil}
                            />
                          </div>
                        </div>

                        <div data-testid="admin-moderation-votes">
                          <h3 class="text-sm font-medium text-ink">
                            {FeedbackHTML.votes_label(@detail.post.vote_count)}
                          </h3>
                          <p
                            :if={@detail.votes == []}
                            class="mt-1 text-sm text-ink-muted"
                            data-testid="admin-moderation-votes-empty"
                          >
                            {gettext("No votes yet.")}
                          </p>
                          <ul class="mt-2 space-y-1.5">
                            <li
                              :for={vote <- @detail.votes}
                              class="flex flex-wrap items-center justify-between gap-2 rounded-control border border-line bg-panel-raised px-3 py-2"
                              data-testid={"admin-moderation-vote-#{vote.id}"}
                            >
                              <span class="min-w-0 text-sm text-ink">
                                <span class="font-medium">{caster_label(vote)}</span>
                                <span class="text-ink-muted">
                                  · {stamp_text(vote.created_at)}
                                </span>
                              </span>
                              <.button
                                size="sm"
                                variant="secondary"
                                phx-click="open-retract-vote"
                                phx-value-id={vote.id}
                                phx-disable-with={gettext("Opening...")}
                                data-testid={"admin-moderation-retract-#{vote.id}"}
                              >
                                {gettext("Retract")}
                              </.button>
                            </li>
                          </ul>
                          <%!-- The vote's confirm is the LIGHT inline
                          shape: one question, one consequence line, a
                          plain bordered strip. The heavy danger panel is
                          the post destroy's alone. --%>
                          <div
                            :if={
                              @confirm && @confirm.kind == :vote &&
                                Enum.any?(@detail.votes, &(&1.id == @confirm.id))
                            }
                            class="mt-3 flex flex-wrap items-center justify-between gap-2 rounded-control border border-line bg-panel-raised px-3 py-2"
                            data-testid="admin-moderation-retract-panel"
                          >
                            <p class="text-sm text-ink">
                              {gettext("Remove this vote? The post's vote count drops by one.")}
                            </p>
                            <div class="flex items-center gap-2">
                              <.button
                                size="sm"
                                variant="secondary"
                                phx-click="confirm-retract-vote"
                                data-testid="admin-moderation-retract-confirm"
                              >
                                {gettext("Remove")}
                              </.button>
                              <.button
                                size="sm"
                                variant="ghost"
                                phx-click="cancel-confirm"
                                data-testid="admin-moderation-retract-cancel"
                              >
                                {gettext("Cancel")}
                              </.button>
                            </div>
                          </div>
                        </div>

                        <div data-testid="admin-moderation-comments">
                          <h3 class="text-sm font-medium text-ink">
                            {FeedbackHTML.comments_label(@detail.post.comment_count)}
                          </h3>
                          <p
                            :if={@detail.comments == []}
                            class="mt-1 text-sm text-ink-muted"
                            data-testid="admin-moderation-comments-empty"
                          >
                            {gettext("No comments yet.")}
                          </p>
                          <div class="mt-2 space-y-2">
                            <article
                              :for={comment <- @detail.comments}
                              class="rounded-panel border border-line bg-panel-raised px-3 py-2"
                              data-testid={"admin-moderation-comment-#{comment.id}"}
                            >
                              <div class="flex flex-wrap items-center justify-between gap-2 text-sm">
                                <span class="min-w-0 text-ink">
                                  <span class="font-medium">{comment.author_username}</span>
                                  <span class="text-ink-muted">
                                    · {stamp_text(comment.created_at)}
                                  </span>
                                </span>
                                <.button
                                  size="sm"
                                  variant="secondary"
                                  phx-click="open-delete-comment"
                                  phx-value-id={comment.id}
                                  phx-disable-with={gettext("Opening...")}
                                  data-testid={"admin-moderation-comment-delete-#{comment.id}"}
                                >
                                  {gettext("Delete")}
                                </.button>
                              </div>
                              <%!-- The body rides the body_html calculation:
                              the same sanitized renderer the public board
                              uses, computed at read. --%>
                              <div class="feedback-body mt-1.5 text-sm leading-relaxed text-ink [overflow-wrap:anywhere]">
                                {raw(comment.body_html)}
                              </div>
                            </article>
                          </div>
                          <div
                            :if={
                              @confirm && @confirm.kind == :comment &&
                                Enum.any?(@detail.comments, &(&1.id == @confirm.id))
                            }
                            class="mt-3"
                          >
                            <.confirm_block
                              title={gettext("Delete this comment?")}
                              body={
                                gettext(
                                  "The comment is removed from the post. The post's comment count drops by one. This cannot be undone."
                                )
                              }
                              action={gettext("Yes, delete this comment")}
                              event="confirm-delete-comment"
                              action_testid="admin-moderation-comment-delete-confirm"
                              cancel_testid="admin-moderation-comment-delete-cancel"
                              return_focus={
                                "[data-testid='admin-moderation-comment-delete-#{@confirm.id}']"
                              }
                              myself={nil}
                            />
                          </div>
                        </div>
                      </div>
                    </div>
                  </div>
                </div>
              </div>

              <%!-- The tag vocabulary: the curated list the board filters
              by. Create and rename are plain CRUD; a delete on a USED
              tag names the untag consequence before it runs, an unused
              tag has no destructive consequence and goes in one click. --%>
              <.card class="space-y-4" data-testid="admin-moderation-tags">
                <div>
                  <h2 class="text-base font-medium text-ink">{gettext("Tag vocabulary")}</h2>
                  <p class="mt-1 text-sm text-ink-muted">
                    {gettext(
                      "The board's curated topic tags. Deleting a tag takes it off every post that carries it."
                    )}
                  </p>
                </div>

                <.form
                  for={@tag_form}
                  id="admin-moderation-tag-create"
                  phx-change="validate-tag"
                  phx-submit="create-tag"
                  class="space-y-3"
                >
                  <div class="grid items-start gap-3 sm:grid-cols-2">
                    <.input
                      field={@tag_form[:name]}
                      type="text"
                      label={gettext("Name")}
                      placeholder={gettext("New tag name")}
                      data-testid="admin-moderation-tag-name"
                    />
                    <.input
                      field={@tag_form[:slug]}
                      type="text"
                      label={gettext("Slug")}
                      placeholder={gettext("Optional, derived from the name")}
                      data-testid="admin-moderation-tag-slug"
                    />
                  </div>
                  <.button
                    type="submit"
                    phx-disable-with={gettext("Creating...")}
                    data-testid="admin-moderation-tag-create-submit"
                  >
                    {gettext("Create tag")}
                  </.button>
                </.form>

                <div class="rounded-panel border border-line">
                  <div class={[
                    "grid-cols-[minmax(0,1fr)_4rem_8rem]",
                    AdminComponents.admin_table_header_class()
                  ]}>
                    <div>{gettext("Tag")}</div>
                    <div>{gettext("Posts")}</div>
                    <div class="sr-only">{gettext("Actions")}</div>
                  </div>

                  <p
                    :if={@tags_empty?}
                    class="px-3 py-4 text-sm text-ink-muted"
                    data-testid="admin-moderation-tags-empty"
                  >
                    {gettext("No tags yet. Create the first one above.")}
                  </p>

                  <%!-- The separator rides this stream wrapper. The grid
                  inside stays pure shared chrome (#602). --%>
                  <div id="admin-moderation-tags-list" phx-update="stream">
                    <div
                      :for={{dom_id, tag} <- @streams.tags}
                      id={dom_id}
                      class="border-b border-line last:border-0"
                    >
                      <div class={[
                        "grid-cols-[minmax(0,1fr)_4rem_8rem]",
                        AdminComponents.admin_table_row_class()
                      ]}>
                        <div class="min-w-0">
                          <p
                            class="truncate text-sm font-medium text-ink"
                            data-testid={"admin-moderation-tag-name-#{tag.id}"}
                          >
                            {tag.name}
                          </p>
                          <p class="truncate font-mono text-xs text-ink-muted">
                            {tag.slug}
                          </p>
                        </div>
                        <div>
                          <span
                            class="text-sm text-ink-muted"
                            data-testid={"admin-moderation-tag-usage-#{tag.id}"}
                          >
                            {length(tag.post_tags)}
                          </span>
                        </div>
                        <div>
                          <div class="flex items-center justify-end gap-2">
                            <button
                              type="button"
                              phx-click="open-rename-tag"
                              phx-value-id={tag.id}
                              phx-disable-with={gettext("Opening...")}
                              class="text-sm font-medium text-link underline-offset-2 hover:underline disabled:pointer-events-none disabled:opacity-50"
                              data-testid={"admin-moderation-tag-rename-#{tag.id}"}
                            >
                              {gettext("Rename")}
                            </button>
                            <button
                              type="button"
                              phx-click="open-delete-tag"
                              phx-value-id={tag.id}
                              phx-disable-with={gettext("Deleting...")}
                              class="text-sm font-medium text-ink-muted underline-offset-2 hover:text-ink hover:underline disabled:pointer-events-none disabled:opacity-50"
                              data-testid={"admin-moderation-tag-delete-#{tag.id}"}
                            >
                              {gettext("Delete")}
                            </button>
                          </div>
                        </div>
                      </div>

                      <%!-- The rename form expands under its row (the same
                      posture as the confirm panels), one at a time. --%>
                      <div :if={@tag_rename_id == tag.id} class="px-4 pb-4">
                        <.form
                          for={@tag_rename_form}
                          id="admin-moderation-tag-rename"
                          phx-change="validate-tag-rename"
                          phx-submit="save-tag-rename"
                          class="space-y-3"
                        >
                          <.input
                            field={@tag_rename_form[:name]}
                            type="text"
                            label={gettext("Name")}
                            data-testid="admin-moderation-tag-rename-name"
                          />
                          <div class="flex items-center gap-2">
                            <.button
                              type="submit"
                              phx-disable-with={gettext("Saving...")}
                              data-testid="admin-moderation-tag-rename-save"
                            >
                              {gettext("Save")}
                            </.button>
                            <.button
                              type="button"
                              variant="ghost"
                              size="sm"
                              phx-click="cancel-rename-tag"
                              data-testid="admin-moderation-tag-rename-cancel"
                            >
                              {gettext("Cancel")}
                            </.button>
                          </div>
                        </.form>
                      </div>

                      <div
                        :if={@confirm && @confirm.kind == :tag && @confirm.id == tag.id}
                        class="px-4 pb-4"
                      >
                        <.confirm_block
                          title={gettext("Delete the tag %{name}?", name: @confirm.name)}
                          body={
                            ngettext(
                              "The tag comes off every post that carries it. 1 post carries it today. This cannot be undone.",
                              "The tag comes off every post that carries it. %{count} posts carry it today. This cannot be undone.",
                              @confirm.usage
                            )
                          }
                          action={gettext("Yes, delete this tag")}
                          event="confirm-delete-tag"
                          action_testid="admin-moderation-tag-delete-confirm"
                          cancel_testid="admin-moderation-tag-delete-cancel"
                          return_focus={"[data-testid='admin-moderation-tag-delete-#{@confirm.id}']"}
                          myself={nil}
                        />
                      </div>
                    </div>
                  </div>
                </div>
              </.card>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
