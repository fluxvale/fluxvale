defmodule FluxValeWeb.Storybook.StorySmokeTest do
  @moduledoc false

  # Every story file compiles and its variations render (#178's gate,
  # extended to the backups panel's presentational components). A broken
  # story is a broken design-system reference, and the storybook route
  # would only surface it to whoever opened that page.
  #
  # `async: false` on purpose: the gate reads the global
  # `:storybook_enabled` flag, and `StorybookEnabledTest` flips it to
  # exercise the 404 path. Sync tests run after every async one, so the
  # two can't interleave — an async run here 404s at random.
  use FluxValeWeb.ConnCase, async: false

  @stories [
    {"backup_run_row", "Backup Run Row"},
    {"readonly_field", "Readonly Field"}
  ]

  test "the backups panel's stories load and list their variations" do
    for {slug, title} <- @stories do
      conn = get(build_conn(), "/storybook/components/#{slug}")

      assert html_response(conn, 200) =~ title
    end
  end
end
