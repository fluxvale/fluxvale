defmodule FluxValeWeb.HealthController do
  use FluxValeWeb, :controller

  alias FluxVale.Repo

  # Liveness + build identity. Deliberately dependency-free: a liveness
  # failure tells Kubernetes to restart the pod, and a dependency blip
  # (e.g. the database) must never trigger a restart storm.
  def show(conn, _params) do
    render(conn, :show, status: "ok")
  end

  # Readiness — "gates traffic" (docs/deployment.md): a pod stays out of the
  # Service/Traefik endpoints until the database answers. Fails soft with
  # 503 + unhealthy rather than raising.
  def ready(conn, _params) do
    if db_up?() do
      render(conn, :show, status: "ok")
    else
      conn
      |> put_status(:service_unavailable)
      |> render(:show, status: "unhealthy")
    end
  end

  defp db_up? do
    case Repo.query("SELECT 1", [], timeout: 500, pool_timeout: 500) do
      {:ok, _result} -> true
      {:error, _reason} -> false
    end
  rescue
    # Connection-level failures (database unreachable) raise rather than
    # returning {:error, _} — both shapes mean "not ready".
    _error -> false
  end
end
