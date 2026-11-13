defmodule FluxVale.Catalog.AppVersion.MonthlyRateTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias FluxVale.Catalog.AppVersion
  alias FluxVale.Catalog.AppVersion.MonthlyRate

  test "a sizeless version reads nil — the prompt never quotes a guess" do
    version = %AppVersion{recommended_size: nil, default_storage_gb: 0}

    assert MonthlyRate.calculate([version], [], %{}) == [nil]
  end
end
