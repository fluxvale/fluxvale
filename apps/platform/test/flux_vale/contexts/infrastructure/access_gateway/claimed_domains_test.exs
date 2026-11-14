defmodule FluxVale.Infrastructure.AccessGateway.ClaimedDomainsTest do
  use ExUnit.Case, async: true

  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessGateway.ClaimedDomains

  test "sorts the claimed names and degrades a non-map value to []" do
    records = [
      %AccessGateway{dns_claims: %{"b.example.com" => %{}, "a.example.com" => %{}}},
      %AccessGateway{dns_claims: nil},
      %AccessGateway{dns_claims: %Ash.NotLoaded{field: :dns_claims, type: :attribute}}
    ]

    assert ClaimedDomains.calculate(records, [], %{}) == [
             ["a.example.com", "b.example.com"],
             [],
             []
           ]
  end
end
