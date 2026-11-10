defmodule FluxValeWeb.AdminLive.WalletDetail do
  @moduledoc """
  One wallet's oversight view (#501): the org's facts (balance and the
  runway projection via the domain's `compute_runway/1`), the paywall
  waiver with its contract in plain copy, and the ledger — keyset
  paginated, newest first, the #123 history shape. The writes are the
  three the surface owns:

  - the paywall waiver flip (`Wallet :set_waiver`, the one
    actor-facing wallet update): confirmed inline where the toggle
    lives. The card carries the contract (the waiver satisfies only
    the has-paid gate, moves no money, posts no ledger row); the
    confirm states the delta, branching on purchase history — the
    gate reads the waiver OR the ledger's purchase rows, so removing
    the flag from an org that has paid closes nothing;
  - the goodwill credit (`LedgerEntry :grant_goodwill`, #140): the
    submit opens a confirm that states the consequence, because the
    post is irreversible. The action is KEYLESS by deliberation (the
    domain comment owns the reasoning), so the surface fences the
    wire at both clicks (`phx-disable-with`) and the posted row
    renders at the top of the ledger with a reversal affordance — the
    operator review of the posted row is the guard the domain names;
  - the reversal (`LedgerEntry :reverse`, #577, the compensating
    unwind): confirmed under its row, the original stays.

  Every write re-resolves the actor from the session first
  (`UserAuth.resolve_user/1`, which also re-checks token revocation)
  and requires the platform-admin role on the fresh struct: AdminChrome
  resolves `current_user` once, at mount, and a socket outlives a
  demotion. Every write is policy-gated at the domain; the reversal
  rides the `LedgerEntry :reverse` action (#577), under the same admin
  policy as the goodwill credit. This per-event re-resolve is the
  demotion window's defense, not the authorization decision.

  Reads ride the billing domain with the authorization on. No
  `authorize?: false` anywhere on this surface.
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Accounts.Organization
  alias FluxVale.Billing
  alias FluxVale.Billing.LedgerEntry
  alias FluxVale.Billing.Wallet
  alias FluxVale.Checks.ActorIsPlatformAdmin
  alias FluxVale.Identity.User
  alias FluxValeWeb.AdminComponents
  alias FluxValeWeb.AdminShell
  alias FluxValeWeb.BillingComponents
  alias FluxValeWeb.Components.AdminDataTable
  alias FluxValeWeb.UserAuth

  require Ash.Query

  # The ledger's data-table contract (#501): KEYSET pagination (this
  # is the one read that has it — the ledger is append-only, so a
  # cursor survives inserts landing between pages, where an offset
  # window would skip or repeat rows). Page sizes 25/50/100; the
  # cursor and the sort ride the URL, so a ledger view is shareable.
  # The sortable fields are When and Amount; the cursor binds the
  # sort it was minted under, so a sort change drops the cursors and
  # restarts at the newest page.
  @sortable [:created_at, :amount]
  @sizes AdminDataTable.default_sizes()

  # The goodwill ceiling: the friends-beta reality is small gestures,
  # and the keyless post has no payment rail behind it to dispute — a
  # fat-fingered zero (or a crafted one) should not mint a life-changing
  # credit that only a reversal can claw back. $1,000. Revisit trigger:
  # real payment rails or a per-org goodwill policy.
  @goodwill_max_cents 100_000

  @impl Phoenix.LiveView
  def mount(%{"id" => id}, session, socket) do
    admin = socket.assigns.current_user

    with {:ok, wallet} <- Ash.get(Wallet, id, actor: admin),
         {:ok, [org]} <- org_lookup(admin, [wallet.organization_id]) do
      case Billing.compute_runway(wallet) do
        {:ok, runway} ->
          {:ok,
           assign(socket,
             # The session map, kept for the per-write actor re-resolve
             # (see `reauthorized_actor/1`).
             admin_session: session,
             wallet: wallet,
             org: org,
             runway: runway,
             # The ledger's view state is handle_params' business (the
             # URL is the source of truth); the reversal markers start
             # empty and grow with every visited page.
             reversed_ids: MapSet.new(),
             confirm: nil,
             goodwill_form: to_form(%{"amount_cents" => ""}, as: :goodwill),
             goodwill_echo: nil
           )}

        # defensive: the projection fails only on a DB read failure —
        # not simulatable under the sandbox
        # coveralls-ignore-start
        {:error, _reason} ->
          {:ok,
           socket
           |> put_flash(:error, gettext("The wallet's numbers did not load. Try again."))
           |> push_navigate(to: ~p"/admin/billing")}

          # coveralls-ignore-stop
      end
    else
      # Unknown id (and the org-lookup empty arm, unreachable while the
      # org FK stands): one arm, one answer.
      _missing_or_denied ->
        {:ok,
         socket
         |> put_flash(:error, gettext("That wallet does not exist."))
         |> push_navigate(to: ~p"/admin/billing")}
    end
  end

  # The ledger's view state: sort, page size, and the keyset cursor
  # ride query params, parsed with garbage-proof fallbacks. A bad
  # cursor falls back to the newest page (see refresh_ledger).
  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    state = AdminDataTable.parse_params(params, sortable: @sortable)

    {:noreply,
     socket
     |> assign(table: state, columns: ledger_columns())
     |> refresh_ledger()}
  end

  # -- events ---------------------------------------------------------------

  # The header sort: whitelisted fields only, click-to-toggle. The
  # cursors drop with the sort — a cursor is only valid under the sort
  # it was minted for.
  @impl Phoenix.LiveView
  def handle_event("sort", %{"field" => raw_field}, socket) do
    sort = AdminDataTable.toggle_sort(socket.assigns.table.sort, raw_field, @sortable)

    # A crafted field leaves the sort as it was: a true no-op, no
    # cursor drop, no patch.
    if sort == socket.assigns.table.sort do
      {:noreply, socket}
    else
      push_view(socket, %{
        socket.assigns.table
        | sort: sort,
          after: nil,
          before: nil
      })
    end
  end

  # A crafted field is not a crash: the sort stays as it was.
  def handle_event("sort", _params, socket), do: {:noreply, socket}

  def handle_event("page", %{"nav" => "prev"}, socket) do
    cursor = socket.assigns.ledger_meta.prev_cursor

    if cursor do
      state = %{socket.assigns.table | before: cursor, after: nil}
      push_view(socket, state)
    else
      {:noreply, socket}
    end
  end

  def handle_event("page", %{"nav" => "next"}, socket) do
    cursor = socket.assigns.ledger_meta.next_cursor

    if cursor do
      state = %{socket.assigns.table | after: cursor, before: nil}
      push_view(socket, state)
    else
      {:noreply, socket}
    end
  end

  # A crafted page event is a no-op.
  def handle_event("page", _params, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_event("size", %{"size" => raw}, socket) do
    size = AdminDataTable.parse_size(raw)
    state = %{socket.assigns.table | size: size, after: nil, before: nil}

    push_view(socket, state)
  end

  def handle_event("size", _params, socket), do: {:noreply, socket}

  # The waiver lever's click. The reveal rides a fresh domain read, so
  # the direction the confirm states is the wallet's CURRENT state, not
  # the mounted snapshot's (a flip raced between mount and click reads
  # the truth). The purchase-existence check rides along: the removal
  # copy branches on it, because the gate reads the waiver OR the
  # ledger's purchase rows.
  @impl Phoenix.LiveView
  # coveralls-ignore-start - OTP 28 cover never attributes a count to
  # this clause head; the clause demonstrably runs (the waiver tests
  # drive it and the body's own lines all carry counts)
  def handle_event("open-waiver", _params, socket) do
    admin = socket.assigns.current_user
    # coveralls-ignore-stop

    case Ash.get(Wallet, socket.assigns.wallet.id, actor: admin) do
      {:ok, fresh} ->
        paid? = has_purchase?(fresh, admin)

        {:noreply,
         assign(socket, confirm: {:waiver, not fresh.paywall_waived, paid?}, wallet: fresh)}

      # Wallet rows are never deleted, so this arm is the DB-down
      # class — not simulatable under the sandbox.
      # coveralls-ignore-start
      {:error, _vanished} ->
        refused =
          put_flash(
            socket,
            :error,
            gettext("The wallet's state did not load. Try again.")
          )

        {:noreply, refused}
        # coveralls-ignore-stop
    end
  end

  # The waiver write: the one actor-facing wallet update, absolute
  # value, so the confirmed direction lands even if another admin
  # flipped in between (last confirmed intent wins — the flash states
  # the resulting state either way).
  def handle_event("confirm-waiver", _params, socket) do
    case socket.assigns.confirm do
      {:waiver, target, paid?} ->
        case reauthorized_actor(socket) do
          {:ok, admin} ->
            attempt_waiver(socket, target, paid?, admin)

          # coveralls-ignore-start - wire-unreachable behind the
          # AdminChrome per-event hook, which refuses every event from
          # a demoted actor before the handler runs (the demotion test
          # pins the hook): the arm keeps the handler independently
          # safe should that hook ever move.
          :revoked ->
            {:noreply,
             socket
             |> put_flash(:error, revoked_copy())
             |> assign(confirm: nil)}

            # coveralls-ignore-stop
        end

      # A second confirm click (or a stale frame naming the other
      # panel): the confirm already closed. A quiet no-op — the panel
      # the event belonged to is gone, so there is nothing to say.
      _expired ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel-confirm", _params, socket) do
    case socket.assigns.confirm do
      {:reverse, entry} ->
        # The panel lives inside the stream row, so the row re-renders.
        {:noreply,
         socket
         |> assign(confirm: nil)
         |> stream_insert(:entries, entry)}

      _other_or_nil ->
        {:noreply, assign(socket, confirm: nil)}
    end
  end

  # The dollar echo under the cents input: live, so the operator sees
  # the money they are about to confirm before the confirm exists.
  @impl Phoenix.LiveView
  def handle_event("goodwill-echo", %{"goodwill" => %{"amount_cents" => raw}}, socket) do
    echo =
      case parse_cents(raw) do
        {:ok, cents} -> BillingComponents.format_balance(cents)
        :error -> nil
      end

    {:noreply, assign(socket, goodwill_echo: echo)}
  end

  # The goodwill submit opens the confirm — it does not post. The
  # action is keyless by deliberation (each submit posts), so the
  # surface puts a confirm between the click and the wire and fences
  # both clicks with phx-disable-with.
  @impl Phoenix.LiveView
  # coveralls-ignore-start - the same clause-head cover artifact; the
  # goodwill tests drive it and the body's lines carry counts
  def handle_event("grant-goodwill", %{"goodwill" => %{"amount_cents" => raw}}, socket) do
    # coveralls-ignore-stop

    # The surface refuses politely before the domain ever sees it: a
    # whole number of US cents, at least 1, at most the ceiling. The
    # action's own constraint stays the arbiter.
    case parse_cents(raw) do
      {:ok, cents} when cents <= @goodwill_max_cents ->
        {:noreply,
         assign(socket,
           confirm: {:goodwill, cents},
           goodwill_form: to_form(%{"amount_cents" => raw}, as: :goodwill)
         )}

      {:ok, _over} ->
        {:noreply,
         socket
         |> put_flash(:error, amount_over_ceiling_copy())
         |> assign(goodwill_form: to_form(%{"amount_cents" => raw}, as: :goodwill))}

      :error ->
        {:noreply,
         socket
         |> put_flash(:error, amount_invalid_copy(raw))
         |> assign(goodwill_form: to_form(%{"amount_cents" => raw}, as: :goodwill))}
    end
  end

  # The goodwill write. Irreversible by design (no unpost, only a
  # compensating reversal), gated on the re-resolved actor like every
  # write here.
  # coveralls-ignore-start - the same clause-head cover artifact; the
  # goodwill confirm tests drive it and the body's lines carry counts
  def handle_event("confirm-goodwill", _params, socket) do
    # coveralls-ignore-stop
    case socket.assigns.confirm do
      {:goodwill, cents} ->
        case reauthorized_actor(socket) do
          {:ok, admin} ->
            attempt_goodwill(socket, cents, admin)

          # coveralls-ignore-start - wire-unreachable behind the
          # AdminChrome per-event hook (see confirm-waiver's arm).
          :revoked ->
            {:noreply,
             socket
             |> put_flash(:error, revoked_copy())
             |> assign(confirm: nil)}

            # coveralls-ignore-stop
        end

      _expired ->
        {:noreply, socket}
    end
  end

  # The reversal lever's click. The reveal rides a fresh actor-
  # authorized domain read (server-side state check), and the row's own
  # facts gate the rest: only a credit of THIS wallet that is not
  # itself a reversal opens the confirm — anything else is answered
  # honestly. A crafted id naming another wallet's entry is a scoping
  # refusal, not a row-moved one: the page never acts outside the
  # wallet it renders.
  def handle_event("open-reverse", %{"id" => id}, socket) do
    admin = socket.assigns.current_user

    case Ash.get(LedgerEntry, id, actor: admin) do
      {:ok, entry} ->
        cond do
          entry.wallet_id != socket.assigns.wallet.id ->
            {:noreply,
             socket
             |> put_flash(:error, gettext("That entry belongs to a different wallet."))
             |> refresh_ledger()}

          entry.type == :credit and is_nil(entry.reverses_id) ->
            {:noreply,
             socket
             |> assign(confirm: {:reverse, entry})
             |> stream_insert(:entries, entry)}

          true ->
            {:noreply,
             socket
             |> put_flash(:error, gettext("That entry changed. The ledger is refreshed."))
             |> refresh_ledger()}
        end

      _not_found ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("That entry changed. The ledger is refreshed."))
         |> refresh_ledger()}
    end
  end

  # The compensating unwind: the `LedgerEntry :reverse` action, gated
  # by the same platform-admin policy as the goodwill credit. The
  # actor re-resolves from the session first (a mount-resolved admin
  # survives a demotion; this re-read does not), then the fresh
  # actor-authorized read, then the action. The domain's own guard
  # refuses a double reversal.
  def handle_event("confirm-reverse", _params, socket) do
    case socket.assigns.confirm do
      {:reverse, entry} ->
        case reauthorized_actor(socket) do
          {:ok, admin} ->
            attempt_reverse(socket, admin, entry)

          # coveralls-ignore-start - wire-unreachable behind the
          # AdminChrome per-event hook (see confirm-waiver's arm).
          :revoked ->
            {:noreply,
             socket
             |> put_flash(:error, revoked_copy())
             |> assign(confirm: nil)
             |> refresh_ledger()}

            # coveralls-ignore-stop
        end

      _expired ->
        {:noreply, socket}
    end
  end

  # Every ledger event is a patch: the URL states the view, and
  # handle_params owns the re-query. replace keeps the browser
  # history clean — a table view is a state, not a navigation.
  defp push_view(socket, state) do
    {:noreply,
     push_patch(
       socket,
       to: AdminDataTable.url_for(~p"/admin/billing/wallets/#{socket.assigns.wallet.id}", state),
       replace: true
     )}
  end

  # -- reads ----------------------------------------------------------------

  # The keyset page under the current view state: the sort and the
  # cursor (one direction at a time — a crafted URL carrying both is
  # an invalid page: Ash refuses it and refresh_ledger's error arm
  # falls back to the newest page).
  defp read_ledger(admin, wallet_id, state) do
    query =
      LedgerEntry
      |> Ash.Query.for_read(:list_for_wallet, %{wallet_id: wallet_id}, actor: admin)
      |> apply_sort(state.sort)

    Ash.read(query, page: [limit: state.size] ++ cursor_opts(state), actor: admin)
  end

  defp cursor_opts(state) do
    cond do
      state.after != nil and state.before == nil -> [after: state.after]
      state.before != nil and state.after == nil -> [before: state.before]
      true -> []
    end
  end

  # The ledger's page: newest first by default, one server-driven
  # keyset window. A crafted or stale cursor is not a crash — the
  # honest answer is the newest page under the current sort, once.
  # The reversal markers merge across every visited page (a reversal
  # sorts ABOVE its original, so a page can carry a compensation whose
  # original sits on another one), and the ledger is append-only, so
  # a merged marker is always a true fact.
  defp refresh_ledger(socket) do
    admin = socket.assigns.current_user
    state = socket.assigns.table

    {page, final_state} =
      case read_ledger(admin, socket.assigns.wallet.id, state) do
        {:ok, page} ->
          {page, state}

        {:error, _invalid_cursor} ->
          clean = %{state | after: nil, before: nil}
          {:ok, page} = read_ledger(admin, socket.assigns.wallet.id, clean)
          {page, clean}
      end

    links = AdminDataTable.keyset_links(page)
    reversed = MapSet.union(socket.assigns.reversed_ids, reversed_ids(page.results))

    meta = %{
      query: final_state.query,
      page: 1,
      size: final_state.size,
      sort: final_state.sort,
      showing: length(page.results),
      next_cursor: links.next,
      prev_cursor: links.prev,
      sizes: @sizes,
      sort_event: "sort",
      page_event: "page",
      size_event: "size"
    }

    socket
    |> assign(
      table: final_state,
      ledger_meta: meta,
      ledger_empty?: page.results == [],
      # The list moved under a reset, so an open confirm closes with
      # it (the old read-one-page contract, kept).
      confirm: nil,
      reversed_ids: reversed
    )
    |> stream(:entries, page.results, reset: true)
  end

  # Newest first by default; the id tiebreak gives the keyset the
  # total order it requires.
  defp apply_sort(query, nil), do: Ash.Query.sort(query, created_at: :desc, id: :desc)

  # Whitelisted atoms only — the param path never builds a sort term.
  defp apply_sort(query, {field, dir}) do
    Ash.Query.sort(query, [{field, dir}, {:id, :desc}])
  end

  # The column declarations, built per render so the labels ride the
  # live locale. Tracks and floors are the shared component's data.
  defp ledger_columns do
    [
      %{
        key: :when,
        label: gettext("When"),
        track: "minmax(8.5rem,1fr)",
        sort: :created_at,
        floor_rem: 8.5
      },
      %{key: :entry, label: gettext("Entry"), track: "minmax(8.5rem,1.2fr)", floor_rem: 8.5},
      %{
        key: :amount,
        label: gettext("Amount"),
        track: "5.5rem",
        align: :right,
        sort: :amount
      },
      %{
        key: :reference,
        label: gettext("Reference"),
        track: "minmax(5.5rem,0.9fr)",
        floor_rem: 5.5
      },
      %{
        key: :actions,
        label: gettext("Actions"),
        track: "4.5rem",
        align: :right,
        sr_only: true
      }
    ]
  end

  # -- the gate -------------------------------------------------------------

  # The demotion-window gate behind every write. AdminChrome resolves
  # the actor ONCE, at mount, and a socket outlives a demotion — so the
  # write handlers re-resolve from the session (which also re-checks
  # token revocation) and require the platform-admin role on the FRESH
  # struct. Reads keep the mount-resolved actor: the route pipeline and
  # the AdminGate mount check own that window; the writes own this one.
  defp reauthorized_actor(socket) do
    case UserAuth.resolve_user(socket.assigns.admin_session) do
      %User{} = actor ->
        if ActorIsPlatformAdmin.platform_admin?(actor), do: {:ok, actor}, else: :revoked

      # The revoked-token arm: same refusal as the demoted actor, and
      # unreachable in a test without minting and revoking the live
      # session's jti out-of-band — the demoted-actor test carries the
      # gate's behavior.
      # coveralls-ignore-start
      _not_signed_in ->
        :revoked
        # coveralls-ignore-stop
    end
  end

  defp attempt_waiver(socket, target, paid?, admin) do
    case Wallet.set_waiver(socket.assigns.wallet, %{paywall_waived: target}, actor: admin) do
      {:ok, waived} ->
        {:noreply,
         socket
         |> put_flash(:info, waiver_flash(target, paid?))
         |> assign(wallet: waived, confirm: nil)}

      # The policy admits this actor (re-resolved above), so the
      # residual error class is DB-down — not simulatable under the
      # sandbox.
      # coveralls-ignore-start
      {:error, _refused} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("The waiver was refused. Try again."))
         |> assign(confirm: nil)}

        # coveralls-ignore-stop
    end
  end

  # coveralls-ignore-start - the same clause-head cover artifact; the
  # goodwill confirm tests drive it and the body's lines carry counts
  defp attempt_goodwill(socket, cents, admin) do
    case LedgerEntry.grant_goodwill(socket.assigns.wallet.id, cents, actor: admin) do
      # coveralls-ignore-stop
      {:ok, entry} ->
        {:noreply,
         socket
         |> put_flash(:info, goodwill_posted_copy(cents))
         |> assign(
           goodwill_form: to_form(%{"amount_cents" => ""}, as: :goodwill),
           goodwill_echo: nil,
           ledger_empty?: false,
           confirm: nil
         )
         |> refresh_facts()
         |> stream_insert(:entries, entry, at: 0)}

      # The policy admits this actor (re-resolved above) and the
      # amount passed the guard, so the residual error class is
      # DB-down — not simulatable under the sandbox.
      # coveralls-ignore-start
      {:error, _refused} ->
        refused =
          put_flash(
            socket,
            :error,
            gettext("The credit was refused. Nothing was posted. Try again.")
          )

        {:noreply, refused}
        # coveralls-ignore-stop
    end
  end

  defp attempt_reverse(socket, admin, entry) do
    case Ash.get(LedgerEntry, entry.id, actor: admin) do
      {:ok, fresh} ->
        if fresh.wallet_id == socket.assigns.wallet.id do
          do_reverse(socket, fresh, admin)
        else
          # Defense at the write too: @confirm is only set by
          # open-reverse, which already refuses cross-wallet ids, so
          # this arm is wire-unreachable today — it keeps the page's
          # one rule true no matter what future paths set the confirm.
          # coveralls-ignore-start
          {:noreply,
           socket
           |> put_flash(
             :error,
             gettext("That entry belongs to a different wallet. The ledger is refreshed.")
           )
           |> refresh_ledger()}

          # coveralls-ignore-stop
        end

      # Ledger rows are never deleted (append-only), so this arm is
      # the DB-down class — not simulatable under the sandbox.
      # coveralls-ignore-start
      {:error, _vanished} ->
        {:noreply, reverse_refused(socket)}
        # coveralls-ignore-stop
    end
  end

  defp do_reverse(socket, fresh, admin) do
    case LedgerEntry.reverse(fresh.id, actor: admin) do
      {:ok, reversal} ->
        {:noreply, reversed(socket, fresh, reversal)}

      # ReverseEntry's double-reversal refusal rides through the action
      # as an Ash unknown error (Splode normalizes the bare atom into
      # the wrapped UnknownError shape); the surface answers the same
      # copy.
      {:error,
       %Ash.Error.Unknown{
         errors: [%Ash.Error.Unknown.UnknownError{error: "unknown error: :already_reversed"}]
       }} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("That entry is already reversed. The ledger is refreshed.")
         )
         |> refresh_ledger()}

      # defensive: the posting only fails on a DB failure (the
      # double-reversal guard ran; the unique index backstops the
      # race) — not simulatable under the sandbox. Forbidden lands here
      # too if the per-event gate above is ever removed: it would then
      # need the revoked copy, not the generic one.
      # coveralls-ignore-start
      {:error, _refused} ->
        {:noreply, reverse_refused(socket)}
        # coveralls-ignore-stop
    end
  end

  # -- reads ----------------------------------------------------------------

  # The flagged lookup seam (Organization :admin_lookup) — the same one
  # read the table rides; a wallet's org exists while the FK stands.
  defp org_lookup(admin, ids) do
    {:ok, orgs} =
      Organization
      |> Ash.ActionInput.for_action(:admin_lookup, %{ids: ids}, actor: admin)
      |> Ash.run_action()

    {:ok, orgs}
  end

  # The removal copy's branch fact: the has-paid gate reads the waiver
  # OR the ledger's purchase rows, so removing the waiver from an org
  # that HAS paid closes nothing. This read is the check, through the
  # domain with the admin actor.
  defp has_purchase?(wallet, admin) do
    LedgerEntry
    |> Ash.Query.for_read(:read, %{}, actor: admin)
    |> Ash.Query.filter(wallet_id == ^wallet.id and reason == :purchase)
    |> Ash.exists?(actor: admin)
  end

  # Post-write facts refresh: the balance and the runway projection move
  # with every posted row. Mirror mount's defensive posture — a read
  # failure here (the DB-down class) keeps the page alive with the
  # previous facts rather than crashing AFTER a committed post, which
  # would eat the success flash and invite a double post.
  # coveralls-ignore-start - the failure arm is the DB-down class
  defp refresh_facts(socket) do
    admin = socket.assigns.current_user

    with {:ok, wallet} <- Ash.get(Wallet, socket.assigns.wallet.id, actor: admin),
         {:ok, runway} <- Billing.compute_runway(wallet) do
      assign(socket, wallet: wallet, runway: runway)
    else
      _read_failed ->
        socket
    end
  end

  # coveralls-ignore-stop

  # -- display helpers ------------------------------------------------------

  defp reversed(socket, original, reversal) do
    socket
    |> put_flash(
      :info,
      gettext("Posted the compensating reversal. The original entry stays in the ledger.")
    )
    |> assign(
      confirm: nil,
      reversed_ids: MapSet.put(socket.assigns.reversed_ids, original.id)
    )
    |> refresh_facts()
    |> stream_insert(:entries, original)
    |> stream_insert(:entries, reversal, at: 0)
  end

  # Reached only through the DB-down arms above (the demotion arm has
  # its own flash now) — not simulatable under the sandbox.
  # coveralls-ignore-start
  defp reverse_refused(socket) do
    socket
    |> put_flash(:error, gettext("The reversal was refused. The ledger is refreshed."))
    |> refresh_ledger()
  end

  # coveralls-ignore-stop

  # -- input ----------------------------------------------------------------

  # A whole number of US cents, at least 1. Anything else is refused,
  # never truncated.
  defp parse_cents(raw) do
    trimmed = String.trim(raw || "")

    case Integer.parse(trimmed) do
      {cents, ""} when cents >= 1 -> {:ok, cents}
      _not_a_whole_positive -> :error
    end
  end

  # -- copy -----------------------------------------------------------------

  defp amount_over_ceiling_copy do
    gettext(
      "Goodwill credits cap at %{cap}. Nothing was posted.",
      cap: BillingComponents.format_balance(@goodwill_max_cents)
    )
  end

  defp amount_invalid_copy(raw) do
    trimmed = String.trim(raw || "")

    # A dollar-shaped amount ("5.50"): name the conversion, not just
    # the rule. Two decimal places is the shape the product writes.
    if Regex.match?(~r/^\d+\.\d{1,2}$/, trimmed) do
      [dollars, frac] = String.split(trimmed, ".")

      padded_frac = String.pad_trailing(frac, 2, "0")
      cents = String.to_integer(dollars) * 100 + String.to_integer(padded_frac)

      gettext(
        "Whole cents only. Enter %{cents} for %{amount}. Nothing was posted.",
        cents: Integer.to_string(cents),
        amount: BillingComponents.format_balance(cents)
      )
    else
      gettext("Enter a whole number of US cents, at least 1. Nothing was posted.")
    end
  end

  defp goodwill_posted_copy(cents) do
    gettext(
      "Posted %{amount} as an adjustment credit. It sits at the top of the ledger. It cannot be un-posted, only reversed.",
      amount: BillingComponents.format_balance(cents)
    )
  end

  defp goodwill_confirm_copy(cents) do
    gettext(
      "Posts %{amount} now as an adjustment credit. It cannot be un-posted, only reversed with a compensating entry.",
      amount: BillingComponents.format_balance(cents)
    )
  end

  defp goodwill_confirm_action(cents) do
    gettext("Yes, post %{amount}", amount: BillingComponents.format_balance(cents))
  end

  defp revoked_copy do
    gettext("Your admin access ended. Sign out and sign back in.")
  end

  # The confirm states the DELTA — the card above already carries the
  # contract. Removal branches on purchase history: the gate reads the
  # waiver OR the ledger's purchase rows, so a paid org loses nothing.
  defp waiver_body(true, _paid?) do
    gettext(
      "The has-paid gate opens for this org: private access and backups unlock. No money moves."
    )
  end

  defp waiver_body(false, true) do
    gettext(
      "The waiver flag comes off. The org's purchase history still satisfies the has-paid gate, so nothing changes for this org."
    )
  end

  defp waiver_body(false, false) do
    gettext(
      "The has-paid gate closes again. Private access and backups lock until the org tops up. No money moves."
    )
  end

  defp waiver_flash(true, _paid?) do
    gettext(
      "The paywall gate is waived for this org. Private access and backups are unlocked. No money moved."
    )
  end

  defp waiver_flash(false, true) do
    gettext(
      "The waiver flag is removed. The org's purchase history keeps the has-paid gate satisfied, so nothing changed for this org."
    )
  end

  defp waiver_flash(false, false) do
    gettext(
      "The waiver is removed. The has-paid gate closes again. Private access and backups lock until the org tops up."
    )
  end

  defp waiver_title(true, org_name) do
    gettext("Waive the paywall gate for %{org}?", org: org_name)
  end

  defp waiver_title(false, org_name) do
    gettext("Remove the paywall waiver for %{org}?", org: org_name)
  end

  defp waiver_action(true), do: gettext("Yes, waive the gate")
  defp waiver_action(false), do: gettext("Yes, remove the waiver")

  # Reached only under the match? guards in the template.
  defp waiver_target({:waiver, target, _paid?}), do: target
  defp waiver_paid({:waiver, _target, paid?}), do: paid?
  defp goodwill_cents({:goodwill, cents}), do: cents

  defp flip_label(true), do: gettext("Remove the waiver")
  defp flip_label(false), do: gettext("Waive the gate")

  defp waiver_tone(true), do: "primary"
  defp waiver_tone(false), do: "neutral"

  defp waiver_label(true), do: gettext("Waived")
  defp waiver_label(false), do: gettext("Not waived")

  defp reverse_title(entry) do
    gettext("Reverse the %{amount} credit?",
      amount: BillingComponents.format_balance(entry.amount)
    )
  end

  # -- display helpers ------------------------------------------------------

  # The DANGER presentation gates on the balance alone: the sweep
  # clears the anchor hourly, so an armed-but-recovered wallet (balance
  # back above zero, anchor not yet swept) is not a countdown and must
  # not read as one.
  defp destroy_clock?(runway, _wallet) do
    runway.balance_cents < 0
  end

  defp recovered_but_armed?(runway, wallet) do
    runway.balance_cents >= 0 and not is_nil(wallet.negative_since)
  end

  # Reached only under the negative_since guard in the template.
  defp stamp_text(stamp), do: Calendar.strftime(stamp, "%b %d, %Y")

  # Only a credit that is not itself a reversal, and has no reversal in
  # the loaded pages, offers the lever. Reversals sort ABOVE their
  # originals (newest first), so a page can carry a compensation whose
  # original sits on a later page — load-more merges the markers, and
  # the domain's own guard answers any residual stale click with the
  # honest refresh.
  defp reversible?(entry, reversed_ids) do
    entry.type == :credit and is_nil(entry.reverses_id) and
      not MapSet.member?(reversed_ids, entry.id)
  end

  defp reversing?(entry, {:reverse, opened}), do: entry.id == opened.id
  defp reversing?(_entry, _other), do: false

  defp reverse_return_focus({:reverse, entry}),
    do: "[data-testid='admin-wallet-reverse-#{entry.id}']"

  defp reversed_ids(entries) do
    entries
    |> MapSet.new(& &1.reverses_id)
    |> MapSet.delete(nil)
  end

  # A netted row must not read as live money: the amount strikes and
  # mutes once its compensation exists.
  defp amount_class(entry, reversed_ids) do
    if MapSet.member?(reversed_ids, entry.id) do
      "text-ink-muted line-through decoration-ink-muted/60"
    else
      amount_color(entry.type)
    end
  end

  defp amount_color(:credit), do: "text-success"
  defp amount_color(:debit), do: "text-danger"

  # Distinct tone-and-shape pairs (the people surface's badge grammar):
  # no two reasons ever share both tone and icon in either theme, and
  # danger stays reserved for the destroy clock and the negative
  # balance. Adjustment rides neutral with a dashed border, distinct
  # from usage's solid neutral.
  defp reason_tone(:welcome), do: "primary"
  defp reason_tone(:purchase), do: "success"
  defp reason_tone(:usage), do: "neutral"
  defp reason_tone(:refund), do: "warning"
  defp reason_tone(:adjustment), do: "neutral"

  defp reason_icon(:welcome), do: "hero-sparkles"
  defp reason_icon(:purchase), do: "hero-credit-card"
  defp reason_icon(:usage), do: "hero-cpu-chip"
  defp reason_icon(:refund), do: "hero-arrow-path"
  defp reason_icon(:adjustment), do: "hero-adjustments-horizontal"

  defp reason_badge_class(:adjustment), do: "border-dashed"
  defp reason_badge_class(_other), do: nil

  defp reason_label(:welcome), do: gettext("Welcome credit")
  defp reason_label(:purchase), do: gettext("Purchase")
  defp reason_label(:usage), do: gettext("Usage")
  defp reason_label(:refund), do: gettext("Refund")
  defp reason_label(:adjustment), do: gettext("Adjustment")

  # The posting's provenance, read-only: the provider-prefixed
  # idempotency key (polar:<checkout>, the webhook's second lock) or
  # the accrual subject. Both nullable, nothing minted for display.
  defp reference_text(entry), do: entry.idempotency_key || entry.subject

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
      <div class="appgram console contents" data-testid="admin-wallet-detail">
        <section class="band">
          <div class="wrap pt-8 pb-10">
            <div class="rise">
              <p class="eyebrow">{gettext("Operator console")}</p>
              <h1 class="page-title mt-1.5">{@org.name}</h1>
              <p class="mt-2 max-w-prose text-base text-ink-muted">
                {gettext("The wallet behind %{org}. Balance, runway, and the ledger.", org: @org.name)}
              </p>
              <div class="mt-4">
                <.link
                  navigate={~p"/admin/billing"}
                  data-testid="admin-wallet-back-link"
                  class="text-sm font-medium text-link underline-offset-2 hover:underline"
                >
                  {gettext("Back to wallets")}
                </.link>
              </div>

              <div class="mt-9">
                <BillingComponents.wallet_facts facts={@runway} />
              </div>
            </div>
          </div>
        </section>

        <%!-- The destroy clock's honest gravity: a negative balance is
        a countdown to data deletion, and the card names the deadline.
        The clearing is the sweep's job (hourly), never the top-up's
        instant — the copy says that. A recovered-but-armed wallet gets
        its own quiet card, not the danger one. --%>
        <section class="wrap pt-2 pb-8">
          <div
            :if={destroy_clock?(@runway, @wallet)}
            class="rise rounded-panel border border-line-danger bg-danger-muted px-4 py-3"
            data-testid="admin-wallet-destroy-clock"
          >
            <p class="text-sm font-semibold text-danger-deep">
              {gettext("The balance is below zero.")}
            </p>
            <p class="mt-1 text-sm text-ink">
              <%= if @wallet.negative_since do %>
                {gettext(
                  "The org's instances are stopped and its data is on a destroy clock. The clock started %{start}. Deletion lands %{deadline}. The clock clears at the next automatic check once the balance is back above zero.",
                  start: stamp_text(@wallet.negative_since),
                  deadline: AdminComponents.destroy_deadline_text(@wallet.negative_since)
                )}
              <% else %>
                {gettext(
                  "The org's instances are stopped. The destroy clock starts at the next automatic check. A top-up that puts the balance back above zero clears it there."
                )}
              <% end %>
            </p>
          </div>

          <div
            :if={recovered_but_armed?(@runway, @wallet)}
            class="rise rounded-panel border border-line bg-panel px-4 py-3"
            data-testid="admin-wallet-recovered"
          >
            <p class="text-sm font-semibold text-ink">
              {gettext("The balance recovered.")}
            </p>
            <p class="mt-1 text-sm text-ink-muted">
              {gettext(
                "The destroy clock from the negative episode has not been swept yet. It clears at the next automatic check. Nothing is on a countdown right now."
              )}
            </p>
          </div>
        </section>

        <section class="wrap pt-4 pb-16">
          <div class="rise flex flex-col gap-8 md:flex-row md:gap-12">
            <%!-- The section entry is an ANCESTOR mark (exact: false):
            this page is the wallets section's sub-route, so the
            sidebar's wallets entry carries aria-current="location". --%>
            <AdminShell.sidebar
              current="wallets"
              exact={false}
              pending_requests={@pending_storage_requests}
            />

            <div class="min-w-0 flex-1 space-y-8">
              <div class="grid items-start gap-6 xl:grid-cols-2">
                <%!-- The waiver card: the contract in plain copy, the flip
                confirmed inline where the toggle lives, the confirm stating
                the delta. --%>
                <.card class="space-y-4" data-testid="admin-wallet-waiver-card">
                  <div class="flex items-start justify-between gap-4">
                    <div class="min-w-0">
                      <h2 class="text-base font-medium text-ink">{gettext("Paywall waiver")}</h2>
                      <p class="mt-1 text-sm text-ink-muted">
                        {gettext(
                          "The waiver satisfies only the has-paid gate. It unlocks private access and backups for this org. It moves no money, posts no ledger row, and waives nothing spendable."
                        )}
                      </p>
                    </div>
                    <span class="shrink-0" data-testid="admin-wallet-waiver-state">
                      <.badge tone={waiver_tone(@wallet.paywall_waived)}>
                        <.icon :if={@wallet.paywall_waived} name="hero-key" class="size-3.5" />
                        {waiver_label(@wallet.paywall_waived)}
                      </.badge>
                    </span>
                  </div>
                  <.button
                    variant="secondary"
                    phx-click="open-waiver"
                    phx-disable-with={gettext("Opening...")}
                    data-testid="admin-wallet-waiver-flip"
                  >
                    {flip_label(@wallet.paywall_waived)}
                  </.button>

                  <div :if={match?({:waiver, _, _}, @confirm)}>
                    <.confirm_block
                      title={waiver_title(waiver_target(@confirm), @org.name)}
                      body={waiver_body(waiver_target(@confirm), waiver_paid(@confirm))}
                      action={waiver_action(waiver_target(@confirm))}
                      event="confirm-waiver"
                      action_testid="admin-wallet-waiver-confirm"
                      cancel_testid="admin-wallet-waiver-cancel"
                      return_focus="[data-testid='admin-wallet-waiver-flip']"
                      myself={nil}
                    />
                  </div>
                </.card>

                <%!-- The goodwill credit: the keyless post gets a confirm
            between the click and the wire, because the post cannot be
            undone. The echo shows the dollars before the confirm does. --%>
                <.card class="space-y-4" data-testid="admin-wallet-goodwill-card">
                  <div>
                    <h2 class="text-base font-medium text-ink">{gettext("Goodwill credit")}</h2>
                    <p class="mt-1 text-sm text-ink-muted">
                      <%!-- The cap is literal here: module attributes read as
                  assigns inside HEEx. It is @goodwill_max_cents above
                  (enforced in grant-goodwill); move the two together. --%>
                      {gettext(
                        "Posts as an adjustment credit, up to $1,000.00. A post cannot be undone, only reversed with a compensating entry."
                      )}
                    </p>
                  </div>
                  <.form
                    for={@goodwill_form}
                    id="admin-wallet-goodwill-form"
                    phx-submit="grant-goodwill"
                    phx-change="goodwill-echo"
                    class="space-y-4"
                  >
                    <div>
                      <.input
                        field={@goodwill_form[:amount_cents]}
                        type="number"
                        min="1"
                        step="1"
                        label={gettext("Amount (US cents)")}
                        data-testid="admin-wallet-goodwill-amount"
                      />
                      <p
                        :if={@goodwill_echo}
                        class="mt-1 text-xs text-ink-muted"
                        data-testid="admin-wallet-goodwill-echo"
                      >
                        = {@goodwill_echo}
                      </p>
                    </div>
                    <.button
                      type="submit"
                      phx-disable-with={gettext("Reviewing...")}
                      data-testid="admin-wallet-goodwill-submit"
                    >
                      {gettext("Post credit")}
                    </.button>
                  </.form>

                  <div :if={match?({:goodwill, _}, @confirm)}>
                    <.confirm_block
                      title={
                        gettext(
                          "Post a %{amount} goodwill credit?",
                          amount: BillingComponents.format_balance(goodwill_cents(@confirm))
                        )
                      }
                      body={goodwill_confirm_copy(goodwill_cents(@confirm))}
                      action={goodwill_confirm_action(goodwill_cents(@confirm))}
                      event="confirm-goodwill"
                      action_testid="admin-wallet-goodwill-confirm"
                      cancel_testid="admin-wallet-goodwill-cancel"
                      return_focus="[data-testid='admin-wallet-goodwill-submit']"
                      myself={nil}
                    />
                  </div>
                </.card>
              </div>

              <div class="space-y-4" data-testid="admin-wallet-ledger-section">
                <h2 class="text-lg font-semibold tracking-tight text-ink">
                  {gettext("Ledger")}
                </h2>

                <.card>
                  <div :if={@ledger_empty?} data-testid="admin-wallet-ledger-empty">
                    <.empty_state title={gettext("No activity yet.")} />
                  </div>

                  <%!-- The ledger data table (#501): the shared component
                  owns the chrome, the tracks, the floor, the sort
                  headers, and the pagination. KEYSET mode (the one read
                  that has it): prev/next ride URL cursors, the "Load
                  more" button retired into them. The confirm expands
                  under its row via the expansion slot. --%>
                  <div :if={not @ledger_empty?}>
                    <AdminDataTable.data_table
                      id="admin-wallet-ledger"
                      items={@streams.entries}
                      columns={@columns}
                      meta={@ledger_meta}
                    >
                      <:cell :let={entry} col={:when}>
                        <span class="whitespace-nowrap text-xs text-ink-muted">
                          {Calendar.strftime(entry.created_at, "%b %d, %Y %H:%M UTC")}
                        </span>
                      </:cell>

                      <:cell :let={entry} col={:entry}>
                        <div data-testid={"admin-wallet-entry-#{entry.id}"}>
                          <span class="flex flex-wrap items-center gap-1.5">
                            <.badge
                              tone={reason_tone(entry.reason)}
                              class={reason_badge_class(entry.reason)}
                            >
                              <.icon name={reason_icon(entry.reason)} class="size-3.5" />
                              {reason_label(entry.reason)}
                            </.badge>
                            <%!-- Reversal provenance stays neutral: danger is
                            reserved for the destroy clock and the negative
                            balance. --%>
                            <.badge :if={entry.reverses_id} tone="neutral">
                              <.icon name="hero-arrow-uturn-left" class="size-3.5" />
                              {gettext("Reversal")}
                            </.badge>
                            <.badge :if={MapSet.member?(@reversed_ids, entry.id)} tone="neutral">
                              <.icon name="hero-arrow-uturn-right" class="size-3.5" />
                              {gettext("Reversed")}
                            </.badge>
                          </span>
                        </div>
                      </:cell>

                      <:cell :let={entry} col={:amount}>
                        <span
                          class={[
                            "whitespace-nowrap text-sm tabular-nums",
                            amount_class(entry, @reversed_ids)
                          ]}
                          data-testid={"admin-wallet-amount-#{entry.id}"}
                        >
                          {BillingComponents.format_amount(entry.amount)}
                        </span>
                      </:cell>

                      <:cell :let={entry} col={:reference}>
                        <span
                          class="block truncate font-mono text-xs text-ink-muted"
                          title={reference_text(entry)}
                          data-testid={"admin-wallet-reference-#{entry.id}"}
                        >
                          {reference_text(entry)}
                        </span>
                      </:cell>

                      <:cell :let={entry} col={:actions}>
                        <div class="flex items-center justify-end">
                          <.button
                            :if={reversible?(entry, @reversed_ids)}
                            size="sm"
                            variant="secondary"
                            phx-click="open-reverse"
                            phx-value-id={entry.id}
                            phx-disable-with={gettext("Opening...")}
                            data-testid={"admin-wallet-reverse-#{entry.id}"}
                          >
                            {gettext("Reverse")}
                          </.button>
                        </div>
                      </:cell>

                      <%!-- The confirm expands directly under the row that
                      opened it; one confirm per page (@confirm is the
                      expansion key), so the shared destructive-confirm
                      testid stays safe. --%>
                      <:expansion :let={entry}>
                        <div :if={reversing?(entry, @confirm)} class="pt-3">
                          <.confirm_block
                            title={reverse_title(entry)}
                            body={
                              gettext(
                                "A compensating debit is posted for the same amount. The original entry stays in the ledger. Net effect on the balance: zero."
                              )
                            }
                            action={gettext("Yes, reverse this entry")}
                            event="confirm-reverse"
                            action_testid="admin-wallet-reverse-confirm"
                            cancel_testid="admin-wallet-reverse-cancel"
                            return_focus={reverse_return_focus(@confirm)}
                            myself={nil}
                          />
                        </div>
                      </:expansion>
                    </AdminDataTable.data_table>
                  </div>
                </.card>
              </div>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
