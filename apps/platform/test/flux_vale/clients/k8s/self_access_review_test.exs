defmodule FluxVale.Clients.K8s.SelfAccessReviewTest do
  @moduledoc false

  use ExUnit.Case, async: true
  use Mimic

  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.SelfAccessReview

  setup do
    stub(Kubereq, :attach, fn req, _opts -> req end)
    :ok
  end

  describe "wait_until_allowed/5" do
    test "returns :ok on the first probe when the verb is already visible" do
      expect(Kubereq, :can_i?, fn _req, attributes ->
        assert attributes[:verb] == "create"
        assert attributes[:resource] == "resourcequotas"
        assert attributes[:namespace] == "fluxvale-app-1"
        true
      end)

      assert :ok =
               SelfAccessReview.wait_until_allowed(
                 %{},
                 "fluxvale-app-1",
                 "resourcequotas",
                 "create"
               )
    end

    test "polls until the verb becomes visible" do
      probes = :counters.new(1, [])

      expect(Kubereq, :can_i?, 3, fn _req, _attributes ->
        :counters.add(probes, 1, 1)
        :counters.get(probes, 1) == 3
      end)

      assert :ok =
               SelfAccessReview.wait_until_allowed(%{}, "ns", "resourcequotas", "create",
                 poll_ms: 1,
                 timeout_ms: 1_000
               )
    end

    test "times out with an Error when the verb never becomes visible" do
      stub(Kubereq, :can_i?, fn _req, _attributes -> false end)

      assert {:error, %Error{reason: :timeout} = error} =
               SelfAccessReview.wait_until_allowed(%{}, "ns", "resourcequotas", "create",
                 poll_ms: 1,
                 timeout_ms: 3
               )

      assert error.message =~ "timed out"
      assert error.message =~ "create"
    end

    test "a raising probe reads as not-visible-yet — never escapes into the deploy" do
      # A broken kubeconfig makes attach itself raise; the deploy's
      # {:ok, either-way} contract requires the poll to swallow it and
      # let the deadline bound the wait.
      stub(Kubereq, :attach, fn _req, _opts -> raise ArgumentError, "broken kubeconfig" end)

      assert {:error, %Error{reason: :timeout}} =
               SelfAccessReview.wait_until_allowed(%{}, "ns", "resourcequotas", "create",
                 poll_ms: 1,
                 timeout_ms: 3
               )
    end
  end
end
