defmodule FluxVale.Identity.DeviceCode.FirstPartyClient do
  @moduledoc """
  Guards `:client_id` against the seeded first-party client
  (`config :flux_vale, :device_flow_client_id` — "fluxvale-cli", the
  CLI's constant, OQ #9).

  There is no client registry table yet — that's OQ #9's deliberately
  deferred upgrade half ("the client registry + scope negotiation");
  until it lands, this validation and the mint operation's own
  pre-check are the whole gate, and adding a client is a config
  change away from being a registry change.
  """

  use Ash.Resource.Validation

  @impl Ash.Resource.Validation
  def validate(changeset, _opts, _context) do
    client_id = Ash.Changeset.get_attribute(changeset, :client_id)

    if client_id == first_party_client_id() do
      :ok
    else
      {:error, field: :client_id, message: "unknown client #{client_id}"}
    end
  end

  @doc """
  The seeded first-party client — the mint operation reads it for the
  same pre-check (one tie; the resource is the backstop door).
  """
  @spec first_party_client_id() :: String.t() | nil
  def first_party_client_id, do: Application.get_env(:flux_vale, :device_flow_client_id)
end
