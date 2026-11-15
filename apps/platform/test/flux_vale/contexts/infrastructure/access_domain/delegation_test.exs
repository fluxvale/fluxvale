defmodule FluxVale.Infrastructure.AccessDomain.DelegationTest do
  @moduledoc false

  # #783: the pre-registration delegation set. The pure function is the
  # one owner the resource calculation, the API preview, and the
  # provider's data source all call; the scheme is contract (customer
  # CNAMEs are static), so these pin determinism and the collision
  # property, not just a shape.

  use FluxVale.DataCase, async: true

  alias FluxVale.Infrastructure.AccessDomain
  alias FluxVale.Infrastructure.AccessDomain.DnsRecords
  alias FluxVale.TestSupport.AccountsFixtures

  @records_re ~r/^[0-9a-f]{32}\.acme\.fluxvale\.app$/

  test "one challenge CNAME into the platform's ACME namespace" do
    assert [%{name: name, type: "CNAME", value: target}] =
             AccessDomain.delegation_records("apps.customer.com")

    assert name == "_acme-challenge.apps.customer.com"
    assert target =~ @records_re
  end

  test "deterministic for a domain — re-registration keeps the same target" do
    first = AccessDomain.delegation_records("apps.customer.com")
    second = AccessDomain.delegation_records("apps.customer.com")

    assert first == second
  end

  test "different domains never share a target" do
    values =
      for domain <- [
            "apps.customer.com",
            "customer.com",
            "apps.other.com",
            "apps.customer.co",
            "staging.apps.customer.com"
          ],
          [%{value: value}] <- [AccessDomain.delegation_records(domain)],
          do: value

    assert length(Enum.uniq(values)) == length(values)
  end

  test "the label is the 128-bit truncation of the domain hash" do
    expected =
      :sha256
      |> :crypto.hash("apps.customer.com")
      |> Base.encode16(case: :lower)
      |> binary_part(0, 32)

    assert AccessDomain.delegation_label("apps.customer.com") == expected
    assert String.length(expected) == 32
  end

  describe "the API calculation" do
    test "a custom row renders its delegation" do
      assert [[%{name: "_acme-challenge.apps.customer.com", type: "CNAME", value: target}]] =
               DnsRecords.calculate(
                 [%{kind: :custom, domain: "apps.customer.com"}],
                 [],
                 %{}
               )

      assert target =~ @records_re
    end

    test "a platform row renders [] — the fleet wildcard already covers it" do
      user = AccountsFixtures.user!()
      org = AccountsFixtures.personal_org!(user)

      platform =
        AccessDomain.mint_platform!(
          %{
            domain: Application.fetch_env!(:flux_vale, :instances_base_domain),
            organization_id: org.id
          },
          authorize?: false
        )

      loaded = Ash.load!(platform, :dns_records, authorize?: false)
      assert loaded.dns_records == []
    end
  end
end
