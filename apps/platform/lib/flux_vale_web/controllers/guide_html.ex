defmodule FluxValeWeb.GuideHTML do
  @moduledoc """
  How-to guide pages — one cohesive file per guide so wiring-step
  tweaks are a single-template edit (the policy pages' shape).
  """

  use FluxValeWeb, :html

  embed_templates("guide_html/*")
end
