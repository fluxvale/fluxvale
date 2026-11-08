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
  moderation posts and tags, the wallet ledger), after #596's
  full-bleed pass made the five copies diverge visibly. Kept as
  class-list functions on purpose: the `grid-cols-[...]` tracks stay
  inline per surface (different columns by necessity) and must stay
  literal in each caller. A track built by interpolation inside a
  wrapper component would fall out of Tailwind's source scan and
  silently drop the tracks from the CSS build. Semantic CSS classes in
  app.css would re-express utilities as raw CSS. The design system
  keeps component chrome hand-written Tailwind on the tokens.
  """
  @spec admin_table_header :: String.t()
  def admin_table_header do
    "grid items-center gap-x-1.5 border-b border-line px-3 py-3 text-left text-xs font-medium tracking-wide text-ink-muted uppercase"
  end

  @doc """
  The body-row counterpart of `admin_table_header/0`. The rows carry
  no separator here: each surface draws it on its own wrapper (or, in
  billing's case, appends it to the grid itself, since the stream
  items are the rows there).
  """
  @spec admin_table_row :: String.t()
  def admin_table_row do
    "grid items-center gap-x-1.5 px-3 py-3 transition-colors hover:bg-panel-raised/60"
  end
end
