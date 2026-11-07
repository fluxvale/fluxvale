defmodule FluxValeWeb.PageHTML do
  @moduledoc """
  This module contains pages rendered by PageController.

  See the `page_html` directory for all templates available.
  """
  use FluxValeWeb, :html

  # The landing's own header renders the shared user_menu (#205) — its
  # Admin row (#551) rides the door's own predicate, like the chrome's.
  alias FluxVale.Checks.ActorIsPlatformAdmin

  embed_templates("page_html/*")
end
