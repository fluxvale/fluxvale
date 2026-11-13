defmodule FluxVale.Catalog.Types.IconPath do
  @moduledoc """
  An App's `icon_url` — the tile's logo, vendored into this app and
  served same-origin (#718). A hotlinked icon ties the catalog page's
  `load` event to a third party, and one unresponsive host hung the
  page (#716).

  Accepted shape:

      /images/catalog/<slug>/icon.png
      /images/catalog/<slug>/icon.svg

  `<slug>` is the App slug shape, and the file must be committed under
  `apps/platform/priv/static`. Whitespace, `..` segments, query
  strings, external URLs, `javascript:`, any other filename, and any
  other extension fail at write time. Like `ScreenshotList`: casting
  and validation live here so seeds, AshAdmin, and the API enforce one
  contract.

  `cast_stored/2` is deliberately lenient, the one difference from
  `ScreenshotList`'s re-cast-on-read: rows written before the contract
  (a hotlinked legacy icon) must stay readable so the seed can heal
  them. The write path is the gate, the read path is not.
  """

  use Ash.Type

  # \A/\z (not ^/$, which admit a trailing newline) and a slug shaped
  # like `App.slug` — no whitespace, no `..` segment, no query string.
  @shape ~r{\A/images/catalog/[a-z0-9]([a-z0-9-]*[a-z0-9])?/icon\.(png|svg)\z}
  @accepted_shape "/images/catalog/<slug>/icon.png (or icon.svg)"

  @impl Ash.Type
  def storage_type(_constraints), do: :string

  @impl Ash.Type
  def cast_input(nil, _constraints), do: {:ok, nil}

  def cast_input(path, _constraints) when is_binary(path) do
    if path =~ @shape,
      do: check_vendored(path),
      else: {:error, shape_error(path)}
  end

  def cast_input(other, _constraints), do: {:error, shape_error(other)}

  @impl Ash.Type
  def dump_to_native(nil, _constraints), do: {:ok, nil}
  def dump_to_native(path, _constraints) when is_binary(path), do: {:ok, path}
  def dump_to_native(_other, _constraints), do: {:error, "expected a string icon path"}

  @impl Ash.Type
  def cast_stored(nil, _constraints), do: {:ok, nil}
  def cast_stored(path, _constraints) when is_binary(path), do: {:ok, path}
  def cast_stored(_other, _constraints), do: {:error, "expected a string icon path"}

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
