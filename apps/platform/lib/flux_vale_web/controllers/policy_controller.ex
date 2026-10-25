defmodule FluxValeWeb.PolicyController do
  @moduledoc """
  Customer-facing policy pages (#140): the refund policy publishes at
  `/policies/refund`, linked from the top-up flow before payment. Public
  and anonymous-OK like the catalog (#164) — a policy the buyer can't
  read before paying isn't a policy. Data-deletion joins here when it
  publishes.
  """

  use FluxValeWeb, :controller

  @refund_description "FluxVale credits are non-refundable and never expire"

  def refund(conn, _params) do
    conn
    |> assign(:page_title, "Refund policy · FluxVale")
    |> assign(:page_description, @refund_description)
    |> assign(:canonical_path, "/policies/refund")
    |> render(:refund)
  end
end
