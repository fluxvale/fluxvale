defmodule FluxValeWeb.OAuthHTML do
  @moduledoc """
  The OAuth consent and error surfaces (#766): a focused auth-layout
  card, the same quiet frame the sign-in page uses.
  """

  use FluxValeWeb, :html

  embed_templates("oauth_html/*")
end
