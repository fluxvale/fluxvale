defmodule FluxValeWeb.Storybook do
  @moduledoc """
  The design-system workshop (#178): phoenix_storybook mounted at
  /storybook, showcasing every `FluxValeWeb.CoreComponents` component
  on the amber token set. Hosted at storybook.fluxvale.com (fleet
  routing, internal-only; gate is `StorybookEnabled`).

  Stories live in `apps/platform/storybook/` (mix-project-relative
  `content_path` below); the sidebar mirrors that folder's hierarchy.
  """

  use PhoenixStorybook,
    otp_app: :flux_vale,
    content_path: "storybook",
    css_path: "/assets/css/storybook.css",
    js_path: "/assets/js/storybook.js",
    theme_path: "/assets/css/storybook_theme.css",
    title: "FluxVale Storybook",
    # Lets the workshop's header toggle flip component tokens (the dark
    # token block in app.css also keys off the .dark class).
    color_mode: true,
    color_mode_sandbox_dark_class: "dark"
end
