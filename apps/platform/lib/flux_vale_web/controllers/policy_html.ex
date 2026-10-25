defmodule FluxValeWeb.PolicyHTML do
  @moduledoc """
  Customer-facing policy pages (#140) — one cohesive file per policy so
  advisor wording tweaks are a single-template edit.
  """

  use FluxValeWeb, :html

  embed_templates("policy_html/*")
end
