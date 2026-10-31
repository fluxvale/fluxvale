defmodule FluxVale.Clients.K8s.Resources.PodTest do
  use ExUnit.Case, async: true
  use Mimic

  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Pod

  setup do
    stub(Kubereq, :attach, fn req, _opts -> req end)
    :ok
  end

  @labels %{"app.kubernetes.io/name" => "access-gateway", "fluxvale.io/gateway" => "gw-1"}

  describe "list_by_labels/3" do
    test "returns only the pods carrying EVERY label" do
      expect(Kubereq, :list, fn _req, ns ->
        assert ns == "fluxvale-access"

        {:ok,
         %{
           status: 200,
           body: %{
             "items" => [
               %{"metadata" => %{"labels" => @labels}},
               %{"metadata" => %{"labels" => %{"app.kubernetes.io/name" => "access-gateway"}}},
               %{"metadata" => %{"labels" => Map.put(@labels, "extra", "x")}}
             ]
           }
         }}
      end)

      assert {:ok, [kept, superset]} = Pod.list_by_labels(%{}, "fluxvale-access", @labels)
      assert kept["metadata"]["labels"] == @labels
      # A superset matches (the selector is a subset check).
      assert superset["metadata"]["labels"]["extra"] == "x"
    end

    test "malformed 200 body is a validation error, not a from_response crash" do
      expect(Kubereq, :list, fn _req, _ns ->
        {:ok, %{status: 200, body: %{"unexpected" => true}}}
      end)

      assert {:error, %Error{reason: :validation_error}} = Pod.list_by_labels(%{}, "ns", @labels)
    end

    test "non-200 maps to an Error" do
      expect(Kubereq, :list, fn _req, _ns -> {:ok, %{status: 403, body: %{}}} end)

      assert {:error, %Error{reason: :forbidden}} = Pod.list_by_labels(%{}, "ns", @labels)
    end
  end

  describe "running_ip/1" do
    test "the IP of a Running pod" do
      pod = %{"status" => %{"phase" => "Running", "podIP" => "10.0.0.9"}}
      assert Pod.running_ip(pod) == "10.0.0.9"
    end

    test "nil for a pending pod" do
      assert Pod.running_ip(%{"status" => %{"phase" => "Pending"}}) == nil
    end
  end

  describe "terminating?/1" do
    test "true when the deletionTimestamp is set" do
      assert Pod.terminating?(%{"metadata" => %{"deletionTimestamp" => "2026-11-01T00:00:00Z"}})
    end

    test "false for a live pod" do
      refute Pod.terminating?(%{"metadata" => %{}})
    end
  end

  describe "started_at/1" do
    test "parses the creationTimestamp" do
      pod = %{"metadata" => %{"creationTimestamp" => "2026-11-01T03:00:00Z"}}
      {:ok, expected, 0} = DateTime.from_iso8601("2026-11-01T03:00:00Z")

      assert Pod.started_at(pod) == expected
    end

    test "an unparseable or missing stamp sorts oldest (never wins the newest-survivor pick)" do
      {:ok, epoch, 0} = DateTime.from_iso8601("1970-01-01T00:00:00Z")

      assert Pod.started_at(%{"metadata" => %{"creationTimestamp" => "garbage"}}) == epoch
      assert Pod.started_at(%{"metadata" => %{}}) == epoch
    end
  end
end
