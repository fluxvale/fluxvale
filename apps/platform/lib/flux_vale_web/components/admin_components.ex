defmodule FluxValeWeb.AdminComponents do
  @moduledoc """
  Shared admin-console render pieces (#501): the allocation string the
  catalog surgery surfaces print for sizes and version defaults — one
  formatter, so the list, the ladder, and both edit forms can never
  disagree about what an allocation reads as.
  """

  use FluxValeWeb, :html

  @doc """
  The allocation a size (or a version's blueprint defaults — both field
  shapes appear on the admin surfaces) reads as: "0.5 CPU, 256 MB,
  0 GB". cpu_cores is a Decimal on both; memory and storage are
  integers.
  """
  @spec allocation_text(map()) :: String.t()
  def allocation_text(record) do
    cpu = dim(record, :cpu_cores, :default_cpu_cores)
    memory = dim(record, :memory_mb, :default_memory_mb)
    storage = dim(record, :storage_gb, :default_storage_gb)

    gettext(
      "%{cpu} CPU, %{memory} MB, %{storage} GB",
      cpu: Decimal.to_string(cpu),
      memory: Integer.to_string(memory),
      storage: Integer.to_string(storage)
    )
  end

  # Sizes carry the bare names; version defaults carry the default_
  # prefix. Zero is a legal storage value, so fetch — never ||.
  defp dim(record, size_field, version_field) do
    case Map.fetch(record, size_field) do
      {:ok, value} -> value
      :error -> Map.fetch!(record, version_field)
    end
  end
end
