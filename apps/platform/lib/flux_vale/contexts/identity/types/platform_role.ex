defmodule FluxVale.Identity.Types.PlatformRole do
  @moduledoc """
  Platform-scoped roles — FluxVale staff standing, global across the app.

  Org-scoped roles are a **separate axis** that lives on `Membership`
  (M5, ADR-0031) and must never be conflated with these. Stored as text:
  adding a value (e.g. `:support`) is a code-only change, no migration.
  """

  use Ash.Type.Enum, values: [:user, :admin]
end
