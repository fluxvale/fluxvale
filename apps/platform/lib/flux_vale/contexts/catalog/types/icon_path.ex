defmodule FluxVale.Catalog.Types.IconPath do
  @moduledoc """
  An App's `icon_url` — the tile's logo, vendored into this app and
  served same-origin (#718). A hotlinked icon ties the catalog page's
  `load` event to a third party, and one unresponsive host hung the
  page (#716).

  Accepted shape:

      /images/catalog/<slug>/icon.png
      /images/catalog/<slug>/icon.svg

  The type owns the write contract: a slug shaped like `App.slug`, the
  `icon` filename with a `png`/`svg` extension, and a file committed
  under `apps/platform/priv/static`. Whitespace, `..` segments, query
  strings, external URLs, `javascript:`, any other filename, and any
  other extension fail at write time.

  The App attribute stays `:string` and `App.CastIconPath` runs this
  cast on create and update, so seeds, AshAdmin, and the API share the
  one contract. Reads use the string attribute, so rows written before
  the contract (a legacy hotlink) stay readable and the seed can heal
  them. A `NewType` over `:string` keeps the JSON:API schema a string.
  The directory must be slug shaped; it is not cross-checked against
  the row's own slug, so any vendored icon path is accepted.

  Not every path that can touch the column is gated: `Ash.Seed.seed!`,
  `Repo.update_all/2`, and direct SQL bypass action changes by design.
  The YAML seed runner goes through the actions and is gated.
  """

  use Ash.Type.NewType, subtype_of: :string

  # \A/\z (not ^/$, which admit a trailing newline) and a slug shaped
  # like `App.slug` — no whitespace, no `..` segment, no query string.
  @shape ~r{\A/images/catalog/[a-z0-9]([a-z0-9-]*[a-z0-9])?/icon\.(png|svg)\z}
  @accepted_shape "/images/catalog/<slug>/icon.png (or icon.svg)"

  @impl Ash.Type
  def cast_input(nil, constraints), do: super(nil, constraints)

  # An empty AshAdmin text field submits "" — the designed absent state
  # is nil. Whitespace-only input is not blank: it falls to the binary
  # clause, `:string` trims it, and the pin below rejects it.
  def cast_input("", _constraints), do: {:ok, nil}

  def cast_input(path, constraints) when is_binary(path) do
    # `:string` trims by default: a padded path comes back changed, so
    # the pin fails and the raw value never reaches the checks below.
    with {:ok, ^path} <- super(path, constraints),
         true <- path =~ @shape do
      check_vendored(path)
    else
      _changed_or_wrong_shape -> {:error, shape_error(path)}
    end
  end

  # `:string` would coerce atoms and numbers; the icon contract must not.
  def cast_input(other, _constraints), do: {:error, shape_error(other)}

  defp check_vendored(path) do
    full_path = static_path(path)

    if File.regular?(full_path),
      do: {:ok, path},
      else: {:error, missing_file_error(path)}
  end

  defp static_path(path) do
    root = Application.app_dir(:flux_vale, "priv/static")
    Path.join(root, path)
  end

  defp shape_error(value),
    do:
      "icon_url must be an app-absolute vendored icon path shaped like " <>
        "#{@accepted_shape}, got: #{inspect(value)}"

  defp missing_file_error(path),
    do:
      "icon_url #{inspect(path)} has no vendored file under priv/static. " <>
        "Accepted shape: #{@accepted_shape}"
end
