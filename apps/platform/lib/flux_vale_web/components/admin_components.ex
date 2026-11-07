defmodule FluxValeWeb.AdminComponents do
  @moduledoc """
  Shared admin-console render pieces (#501): the allocation strings the
  catalog surgery surfaces print — one formatter per shape, so the
  list, the ladder, and both edit forms can never disagree about what
  an allocation reads as. Since #558 a size is a compute class: its
  rows print CPU and memory only, while version blueprints still
  describe the whole allocation (their defaults carry a storage term
  that prices per GB on its own axis).
  """

  use FluxValeWeb, :html

  alias FluxVale.Pricing

  @doc """
  The signed-cents money string the admin billing surfaces print for a
  BALANCE: "-$3.00" / "$12.34". `Pricing.format_usd/1` formats
  non-negative magnitudes only; the balance is the live ledger sum and
  can go negative, so the sign is this display seam's job. One shape,
  one formatter, so the wallet table and the wallet detail can never
  disagree about what a balance reads as.
  """
  @spec money_text(integer()) :: String.t()
  def money_text(cents) when cents < 0 do
    "-" <> Pricing.format_usd(-cents)
  end

  def money_text(cents) when is_integer(cents) do
    Pricing.format_usd(cents)
  end

  @doc """
  The ledger row's signed amount: "+$12.34" / "-$3.00" — a posting is a
  delta, and the sign carries the direction the type badge names
  (BillingComponents' ledger grammar; the admin ledger prints the same
  dollars the org billing page does).
  """
  @spec ledger_amount_text(integer()) :: String.t()
  def ledger_amount_text(cents) when cents < 0 do
    "-" <> Pricing.format_usd(-cents)
  end

  def ledger_amount_text(cents) when is_integer(cents) do
    "+" <> Pricing.format_usd(cents)
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
end
