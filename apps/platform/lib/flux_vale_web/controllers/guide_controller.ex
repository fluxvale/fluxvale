defmodule FluxValeWeb.GuideController do
  @moduledoc """
  User-facing how-to guides. The first is the sign-in-with-Pocket ID
  guide (#511): the wiring steps for one identity across the suite,
  public and anonymous-OK like the policies — the honest-copy weights
  (an identity instance wants always-on, destroying one loses the
  identities it holds) read best before the deploy they inform.
  """

  use FluxValeWeb, :controller

  @sign_in_with_pocket_id_description "One passkey identity for your app suite, wired app by app"

  def sign_in_with_pocket_id(conn, _params) do
    conn
    |> assign(:page_title, "Sign in with Pocket ID · FluxVale")
    |> assign(:page_description, @sign_in_with_pocket_id_description)
    |> assign(:canonical_path, "/guides/sign-in-with-pocket-id")
    |> render(:sign_in_with_pocket_id)
  end
end
