defmodule FluxVale.TestSupport.NoK8sLeaksTest do
  @moduledoc false

  # The helper's own regression pins: random LiveView DOM ids carrying a
  # denylisted substring are markup, not leaks (the CI flake this pins
  # hit a `phx-GOBmk8s…` id); visible copy still fails.

  use ExUnit.Case, async: true

  alias FluxVale.TestSupport.NoK8sLeaks

  test "a random phx id carrying a denylisted substring is not a leak" do
    html = ~s(<div id="phx-GOBmk8sGoB" data-phx-session="abc">All good here</div>)

    assert NoK8sLeaks.refute_k8s_terms(html) == true
  end

  test "a denylisted term in visible text still fails with the leak excerpt" do
    assert_raise ExUnit.AssertionError, ~r/Kubernetes term rendered.*"pod"/s, fn ->
      NoK8sLeaks.refute_k8s_terms("<p>The pod quota was reached</p>")
    end
  end
end
