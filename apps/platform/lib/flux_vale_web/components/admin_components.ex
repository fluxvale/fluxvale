defmodule FluxValeWeb.AdminComponents do
  @moduledoc """
  Shared admin-console render pieces (#501): the allocation strings the
  catalog surgery surfaces print — one formatter per shape, so the
  list, the ladder, and both edit forms can never disagree about what
  an allocation reads as. Since #558 a size is a compute class: its
  rows print CPU and memory only, while version blueprints still
  describe the whole allocation (their defaults carry a storage term
  that prices per GB on its own axis). Also the grid tables' shared
  chrome (#602): one header and one row class list, so the five
  hand-rolled tables can never disagree about the chrome around their
  tracks.
  """

  use FluxValeWeb, :html

  @doc """
  The destroy clock's deadline string: the anchor plus 30 days, the
  sweep's own constant (SweepZeroBalance's @destroy_after_days). One
  formatter so the wallet table and the wallet detail can never
  disagree about when a countdown lands.
  """
  @spec destroy_deadline_text(DateTime.t()) :: String.t()
  def destroy_deadline_text(negative_since) do
    deadline = DateTime.add(negative_since, 30, :day)
    Calendar.strftime(deadline, "%b %d, %Y")
  end

  @doc """
  The allocation a version's blueprint defaults read as: "0.5 CPU ·
  256 MB · 0 GB". The middle-dot shape matches the product's own
  allocation strings (the catalog and instance surfaces); the formatter
  stays admin-local on purpose. default_cpu_cores is a Decimal on the
  record; memory and storage are integers.
  """
  @spec allocation_text(map()) :: String.t()
  def allocation_text(version) do
    gettext(
      "%{cpu} CPU · %{memory} MB · %{storage} GB",
      cpu: Decimal.to_string(version.default_cpu_cores),
      memory: Integer.to_string(version.default_memory_mb),
      storage: Integer.to_string(version.default_storage_gb)
    )
  end

  @doc """
  The compute a size (a compute class, #558) reads as: "0.5 CPU ·
  256 MB". A size prices no storage — storage prices per GB on its own
  axis — so there is no GB term. Same middle-dot shape as
  `allocation_text/1`; cpu_cores is a Decimal, memory an integer.
  """
  @spec compute_text(map()) :: String.t()
  def compute_text(size) do
    gettext("%{cpu} CPU · %{memory} MB",
      cpu: Decimal.to_string(size.cpu_cores),
      memory: Integer.to_string(size.memory_mb)
    )
  end

  @doc """
  The admin grid tables' shared chrome (#602): one header and one row
  class list for the five hand-rolled tables (people, billing wallets,
  moderation posts and tags, the wallet ledger). The five copies were
  byte-identical, not divergent. The motive is five places to drift
  with no single owner. Kept as class-list functions, not a wrapper
  component: these divs also carry id, data-testid, and conditional
  classes at the call sites (stream dom ids, billing's negative-row
  tint), so a component would mean attribute plumbing at ten sites or
  a new wrapper element that changes the markup. The `grid-cols-[...]`
  tracks stay inline per surface (different columns by necessity) and
  stay literal, so Tailwind's source scan keeps emitting them.
  Semantic CSS classes in app.css would re-express utilities as raw
  CSS. The design system keeps component chrome hand-written Tailwind
  on the tokens. The orgs surfaces' tables ride the same chrome.
  """
  @spec admin_table_header_class :: String.t()
  def admin_table_header_class do
    "grid items-center gap-x-3 border-b border-line px-3 py-3 text-left text-xs font-medium tracking-wide text-ink-muted uppercase"
  end

  @doc """
  The body-row counterpart of `admin_table_header_class/0`. The rows
  carry no separator here: each surface draws it on its own wrapper
  (or, in billing's case, appends it to the grid itself, since the
  stream items are the rows there).
  """
  @spec admin_table_row_class :: String.t()
  def admin_table_row_class do
    "grid items-center gap-x-3 px-3 py-3 transition-colors hover:bg-panel-raised/60"
  end

  @doc """
  The allocation a live instance runs at: "0.5 CPU · 256 MB · 12 GB".
  The version blueprint's shape (`allocation_text/1`) over the
  instance's own numbers — an instance still carries the storage term
  (#558 moved the storage axis out of sizes, not out of instances).
  """
  @spec instance_allocation_text(map()) :: String.t()
  def instance_allocation_text(instance) do
    gettext("%{cpu} CPU · %{memory} MB · %{storage} GB",
      cpu: Decimal.to_string(instance.cpu_cores),
      memory: Integer.to_string(instance.memory_mb),
      storage: Integer.to_string(instance.storage_gb)
    )
  end

  # The wallet balance's three-way state (the orgs surfaces' summary
  # badge, #501): negative is the destroy clock's countdown, zero
  # blocks the funded gates (deploys, starts, resizes), positive is
  # the resting rung and takes NO badge at all (the plain state — a
  # green chip on every quiet row reads louder than the alarms).
  # Tone never rides alone — each badged state carries its own icon
  # and word.
  @doc """
  The balance state's parts: `{tone, icon, label}`, or `:none` for the
  resting (positive) rung — the plain state, deliberately unbadged.
  Negative reads as the countdown (danger, clock), zero as the funded
  gate's block (warning, triangle).
  """
  @spec wallet_state(integer()) :: {String.t(), String.t() | nil, String.t()} | :none
  def wallet_state(balance_cents) when balance_cents < 0 do
    {"danger", "hero-clock", gettext("Negative")}
  end

  def wallet_state(0), do: {"warning", "hero-exclamation-triangle", gettext("Zero")}

  def wallet_state(_balance_cents), do: :none

  @doc """
  The badge itself: the state helper's parts as one rendered cue, so
  the two orgs surfaces (the list row and the detail card) show the
  SAME badge. The wallets section renders its own grammar (the waiver
  is that section's state column) — deliberately not shared.
  """
  attr(:balance_cents, :integer, required: true)
  attr(:class, :any, default: nil)

  @spec wallet_state_badge(map()) :: Phoenix.LiveView.Rendered.t()
  def wallet_state_badge(%{balance_cents: balance_cents} = assigns) do
    case wallet_state(balance_cents) do
      :none ->
        ~H"""
        """

      {tone, icon, label} ->
        assigns = assign(assigns, tone: tone, icon: icon, label: label)

        ~H"""
        <.badge tone={@tone} class={@class}>
          <.icon :if={@icon} name={@icon} class="size-3.5" />
          <span>{@label}</span>
        </.badge>
        """
    end
  end

# -- the access-gateway section's state badges (#501, #608 review) ----

  # The gateway and domain state vocabularies ride ONE grammar: tone
  # plus shape cue plus word, at the house badge size, with the rule
  # that no two states ever share BOTH tone and shape (the people
  # surface's discipline). The gateway states keep the product's own
  # words (the #179 split: the shared `status_badge`'s labels) but
  # carry their own shape cues — the review's blocker: the shared
  # component marks Connecting and Needs attention with the same amber
  # dot, which differentiates only in motion. Here Connecting rides a
  # bolt and the shared labels resolve across BOTH machines: one label,
  # one shape, per section and across them (Needs attention is the
  # triangle on a gateway and on a domain, Suspended is the pause).

  attr(:state, :atom, required: true, doc: "an AccessGatewayState value")

  @spec gateway_state_badge(map()) :: Phoenix.LiveView.Rendered.t()
  def gateway_state_badge(assigns) do
    assigns = assign(assigns, cue: gateway_state_cue(assigns.state))

    ~H"""
    <.badge tone={gateway_state_tone(@state)} data-testid="gateway-state-badge">
      <%= case @cue do %>
        <% {:icon, name} -> %>
          <.icon name={name} class="size-3.5" />
        <% {:icon, name, :pulse} -> %>
          <.icon name={name} class="size-3.5 motion-safe:animate-pulse" />
      <% end %>
      {gateway_state_label(@state)}
    </.badge>
    """
  end

  attr(:state, :atom, required: true, doc: "an AccessDomainState value")

  @spec domain_state_badge(map()) :: Phoenix.LiveView.Rendered.t()
  def domain_state_badge(assigns) do
    ~H"""
    <.badge tone={domain_state_tone(@state)} data-testid="domain-state-badge">
      <%= case domain_state_cue(@state) do %>
        <% {:icon, name} -> %>
          <.icon name={name} class="size-3.5" />
        <% {:dot, :pulse} -> %>
          <span class="size-1.5 rounded-full bg-current motion-safe:animate-pulse" />
      <% end %>
      {domain_state_label(@state)}
    </.badge>
    """
  end

  # The gateway states' grammar. The labels are the shared component's
  # (the product's own words, #179), now gettext'd on this surface.
  defp gateway_state_tone(:provisioning), do: "warning"
  defp gateway_state_tone(:active), do: "success"
  defp gateway_state_tone(:needs_attention), do: "warning"
  defp gateway_state_tone(:suspended), do: "neutral"
  defp gateway_state_tone(:destroying), do: "danger"

  defp gateway_state_cue(:provisioning), do: {:icon, "hero-bolt", :pulse}
  defp gateway_state_cue(:active), do: {:icon, "hero-check-circle"}
  defp gateway_state_cue(:needs_attention), do: {:icon, "hero-exclamation-triangle"}
  defp gateway_state_cue(:suspended), do: {:icon, "hero-pause"}
  defp gateway_state_cue(:destroying), do: {:icon, "hero-trash", :pulse}

  defp gateway_state_label(:provisioning), do: gettext("Connecting")
  defp gateway_state_label(:active), do: gettext("Connected")
  defp gateway_state_label(:needs_attention), do: gettext("Needs attention")
  defp gateway_state_label(:suspended), do: gettext("Suspended")
  defp gateway_state_label(:destroying), do: gettext("Removing")

  # The domain states' grammar (the verification life, ADR-0040): the
  # pulse is the non-color half of the in-flight state, the triangle
  # and the pause match their gateway namesakes.
  defp domain_state_tone(:pending), do: "primary"
  defp domain_state_tone(:verified), do: "success"
  defp domain_state_tone(:needs_attention), do: "warning"
  defp domain_state_tone(:failed), do: "danger"
  defp domain_state_tone(:suspended), do: "neutral"

  defp domain_state_cue(:pending), do: {:dot, :pulse}
  defp domain_state_cue(:verified), do: {:icon, "hero-check-circle"}
  defp domain_state_cue(:needs_attention), do: {:icon, "hero-exclamation-triangle"}
  defp domain_state_cue(:failed), do: {:icon, "hero-x-mark"}
  defp domain_state_cue(:suspended), do: {:icon, "hero-pause"}

  defp domain_state_label(:pending), do: gettext("Pending")
  defp domain_state_label(:verified), do: gettext("Verified")
  defp domain_state_label(:needs_attention), do: gettext("Needs attention")
  defp domain_state_label(:failed), do: gettext("Failed")
  defp domain_state_label(:suspended), do: gettext("Suspended")
end
