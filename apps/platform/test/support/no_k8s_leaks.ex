defmodule FluxVale.TestSupport.NoK8sLeaks do
  @moduledoc """
  #179's denylist: no Kubernetes/platform-internal term may render to a
  non-admin on any surface. Shared by the instance/catalog LiveView
  tests so every surface assertion rides one list.

  Deliberately excludes product-legit words ("secret"/"password" are
  env-config vocabulary; "deploy" is FluxVale's own product term) —
  this list is the *platform under the hood*: orchestrator names, k8s
  resource kinds, RBAC wording, and the observed incident's own terms.
  """

  import ExUnit.Assertions, only: [flunk: 1]

  @denylist [
    "kubernetes",
    "k8s",
    "kubectl",
    "helm",
    "namespace",
    "pod",
    "quota",
    "serviceaccount",
    "service account",
    "rbac",
    "forbidden",
    "manifest",
    "deployment",
    "ingress",
    "networkpolicy",
    "rolebinding",
    "clusterrole",
    "cluster",
    "replica",
    "rollout"
  ]

  @doc """
  Asserts `html` contains no denylisted term (case-insensitive). On a
  hit, fails naming the term and a snippet of where it leaked.

  Matches the rendered text, not the markup: LiveView's random DOM ids
  (`phx-Go8k8s…`) can carry a denylisted substring by chance, and the
  helper hunts user-visible copy, not attribute noise.
  """
  @spec refute_k8s_terms(String.t()) :: true
  def refute_k8s_terms(html) when is_binary(html) do
    visible = String.replace(html, ~r/<[^>]*>/, " ")

    leaked = Enum.find(@denylist, &String.contains?(String.downcase(visible), &1))

    if leaked do
      excerpt = leak_excerpt(visible, leaked)

      flunk("""
      Kubernetes term rendered to a non-admin surface (#179): "#{leaked}"
      #{excerpt}
      """)
    else
      true
    end
  end

  defp leak_excerpt(html, term) do
    before_term =
      html
      |> String.downcase()
      |> String.split(term, parts: 2)
      |> List.first()

    start_at = max(0, String.length(before_term) - 120)

    "…" <> String.slice(before_term, start_at, 120) <> term <> "…"
  end
end
