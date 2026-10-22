defmodule FluxVale.Edge do
  @moduledoc """
  Edge-shared predicates for scale-to-zero (#203, ADR-0036): the
  probe/monitor filter the beacon and the wake endpoint must agree on —
  settled owner decision: health probes and uptime monitors must NOT
  count as traffic. Neither the idle clock nor a sleeping instance's
  wake may move on them.

  The list is user-agent prefixes, config-owned
  (`edge_probe_user_agents`): anything a monitoring fleet honestly
  names itself. A browser-like UA used by a dishonest monitor is out of
  scope — indistinguishable from a visitor by design.
  """

  @doc """
  True when the user-agent names a health probe or uptime monitor.
  A nil/absent UA is NOT a probe: filtered lists beat paranoid
  defaults, and every honest probe sends its name.
  """
  @spec probe_request?(String.t() | nil) :: boolean()
  def probe_request?(nil), do: false

  def probe_request?(user_agent) when is_binary(user_agent) do
    patterns = Application.fetch_env!(:flux_vale, :edge_probe_user_agents)

    Enum.any?(patterns, &Regex.match?(&1, user_agent))
  end
end
