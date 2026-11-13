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
  end

  describe "cast_stored/2" do
    # Deliberate leniency: pre-contract rows (a hotlinked legacy icon)
    # must stay readable so the seed can heal them. The write path is
    # the gate.
    test "passes a legacy hotlinked icon_url through unchanged (lenient read)" do
      assert IconPath.cast_stored("https://hotlink.example/legacy.svg", []) ==
               {:ok, "https://hotlink.example/legacy.svg"}
    end

    test "passes nil through" do
      assert IconPath.cast_stored(nil, []) == {:ok, nil}
    end

    test "rejects a non-binary" do
      assert {:error, _message} = IconPath.cast_stored(:atom, [])
    end
  end

  describe "dump_to_native/2" do
    test "passes nil and a path through" do
      assert IconPath.dump_to_native(nil, []) == {:ok, nil}

      assert IconPath.dump_to_native("/images/catalog/forgejo/icon.svg", []) ==
               {:ok, "/images/catalog/forgejo/icon.svg"}
    end

    test "rejects a non-binary" do
      assert {:error, _message} = IconPath.dump_to_native(:atom, [])
    end
  end
end
