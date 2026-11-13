defmodule FluxVale.Infrastructure.Instance.Url do
  @moduledoc """
  The instance's public default URL — `https://<slug>.<instances_base_domain>`
  (ADR-0040 S1: the default hostname is minted from the slug at create).

  A read-only calculation on the instance's detail projection (#765):
  the agent handoff and the CLI need one field to read back, and the
  page already composes this exact string. Custom hostnames are
  additional addresses, never a replacement — this default always
  answers.
  """

  use Ash.Resource.Calculation

  @impl Ash.Resource.Calculation
  def calculate(records, _opts, _context) do
    base_domain = Application.fetch_env!(:flux_vale, :instances_base_domain)

    Enum.map(records, fn instance ->
      "https://#{instance.slug}.#{base_domain}"
    end)
  end
end
