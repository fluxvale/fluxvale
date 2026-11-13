defmodule FluxVale.Catalog.Types.IconPathTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias FluxVale.Catalog.Types.IconPath

  describe "cast_input/2" do
    test "accepts a shipped svg icon under priv/static" do
      path = "/images/catalog/forgejo/icon.svg"

      assert IconPath.cast_input(path, []) == {:ok, path}
    end

    test "accepts a shipped png icon under priv/static" do
      path = "/images/catalog/vikunja/icon.png"

      assert IconPath.cast_input(path, []) == {:ok, path}
    end

    test "rejects a hotlinked icon_url" do
      for url <- ["https://example.com/icon.png", "//cdn.example.com/icon.png"] do
        assert {:error, message} = IconPath.cast_input(url, [])
        assert message =~ "icon_url"
        assert message =~ inspect(url)
      end
    end

    test "rejects a javascript: icon_url" do
      assert {:error, message} = IconPath.cast_input("javascript:alert(1)", [])
      assert message =~ inspect("javascript:alert(1)")
    end

    test "rejects a path outside priv/static" do
      for path <- [
            "/images/other/icon.svg",
            "/etc/passwd",
            "../../etc/passwd",
            "/images/catalog/forgejo/../other/icon.svg"
          ] do
        assert {:error, message} = IconPath.cast_input(path, [])
        assert message =~ "icon_url"
        assert message =~ inspect(path)
      end
    end

    test "rejects a whitespace-padded path (the :string trim does not soften the gate)" do
      for path <- [
            " /images/catalog/forgejo/icon.svg",
            "/images/catalog/forgejo/icon.svg "
          ] do
        assert {:error, message} = IconPath.cast_input(path, [])
        assert message =~ inspect(path)
      end
    end

    test "rejects a missing vendored file" do
      # Other filename than `icon` (the shape arm).
      assert {:error, _message} = IconPath.cast_input("/images/catalog/forgejo/missing.svg", [])

      # Shape-valid, but no file ships at the path (the existence arm).
      assert {:error, message} = IconPath.cast_input("/images/catalog/nosuchapp/icon.svg", [])
      assert message =~ "no vendored file"
      assert message =~ "/images/catalog/nosuchapp/icon.svg"
    end

    test "rejects a wrong extension" do
      assert {:error, message} = IconPath.cast_input("/images/catalog/forgejo/icon.webp", [])
      assert message =~ "icon.svg"
      assert message =~ "/images/catalog/forgejo/icon.webp"
    end

    test "rejects non-strings" do
      assert {:error, _message} = IconPath.cast_input(:atom, [])
      assert {:error, _message} = IconPath.cast_input(123, [])
    end

    test "nil is the absent state" do
      assert IconPath.cast_input(nil, []) == {:ok, nil}
    end

    test "the exact empty string is the absent state (the AshAdmin blank field)" do
      assert IconPath.cast_input("", []) == {:ok, nil}
    end

    test "whitespace-only is not blank and stays rejected" do
      assert {:error, message} = IconPath.cast_input("   ", [])
      assert message =~ inspect("   ")
    end
  end
end
