defmodule FluxVale.ReleaseTest do
  @moduledoc """
  The release DB tasks (`FluxVale.Release.migrate/0`, `seed/0`). The
  functions run unchanged under ExUnit — `with_repo/2` reuses the
  already-started test repo — so the suite exercises the real code and
  only the no-Mix release *environment* stays untested (#98).
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.Identity.User

  test "migrate/0 is a no-op when all migrations are applied" do
    assert :ok = FluxVale.Release.migrate()
  end

  test "seed/0 brings up the admin + catalog" do
    assert :ok = FluxVale.Release.seed()

    assert %{platform_role: :admin} =
             User.get_by_email!("admin@fluxvale.com", authorize?: false)
  end
end
