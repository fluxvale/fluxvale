defmodule FluxValeWeb.PolicyController do
  @moduledoc """
  Customer-facing policy pages (#140): the refund policy publishes at
  `/policies/refund`, linked from the top-up flow before payment. Public
  and anonymous-OK like the catalog (#164) — a policy the buyer can't
  read before paying isn't a policy. The Terms of Service and the
  Acceptable Use Policy (#365) publish beside it; data-deletion joins
  here when it publishes.
  """

  use FluxValeWeb, :controller

  @refund_description "FluxVale credits are non-refundable and never expire"
  @terms_description "The agreement between you and FluxVale"
  @acceptable_use_description "What you may and may not run on FluxVale"

  def refund(conn, _params) do
    conn
    |> assign(:page_title, "Refund policy · FluxVale")
    |> assign(:page_description, @refund_description)
    |> assign(:canonical_path, "/policies/refund")
    |> render(:refund)
  end

  def terms(conn, _params) do
    conn
    |> assign(:page_title, "Terms of Service · FluxVale")
    |> assign(:page_description, @terms_description)
    |> assign(:canonical_path, "/policies/terms")
    |> render(:terms)
  end

  def acceptable_use(conn, _params) do
    conn
    |> assign(:page_title, "Acceptable Use Policy · FluxVale")
    |> assign(:page_description, @acceptable_use_description)
    |> assign(:canonical_path, "/policies/acceptable-use")
    |> render(:acceptable_use)
  end
end
