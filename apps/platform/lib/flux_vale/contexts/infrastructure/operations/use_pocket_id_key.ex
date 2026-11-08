defmodule FluxVale.Infrastructure.Operations.UsePocketIdKey do
  @moduledoc """
  The audited key-use seam (#597 S2, the D1 amendment) — the ONE way
  later slices (S4 wiring, S5 rotate/disconnect) get the held key:
  reads it from the custody Secret and records a `:used` custody
  event, then hands the raw key to the caller. There is no unaudited
  read (`read_api_credential`'s internal-only stance: no user surface
  ever returns the key — this operation IS the internal surface).

  `purpose` is the audit's what-for (a short stable string:
  "verification", "client_mint", "client_rotate", …). `opts` carry
  `actor:` — the member whose action occasioned the use; nil on
  system paths (the event records the system honestly as actor-less).

  Authorization is upstream: callers hold an authorized custody row
  (or ran their own gate); this operation adds the audit, not a
  policy.
  """

  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.Infrastructure.Operations.RecordCustodyEvent
  alias FluxVale.Infrastructure.PocketIdCustody

  @api_key_data_key "POCKETID_API_KEY"

  @doc """
  `{:ok, key}` — the raw admin key, for the caller's PocketID API
  call — or `{:error, reason}`: `:no_api_key` (Secret gone or never
  stored), `:api_key_malformed` (out-of-band tampering), or the
  cluster read failure. A `:used` event lands on every successful
  read.
  """
  @spec call(PocketIdCustody.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def call(%PocketIdCustody{} = custody, purpose, opts \\ []) when is_binary(purpose) do
    with {:ok, instance} <- load_instance(custody),
         {:ok, key} <- read_key(instance, custody) do
      record_event(custody, purpose, opts[:actor])
      {:ok, key}
    end
  end

  # The custody row carries the instance_id the Secret's name derives
  # from (the store op's naming rule); the instance carries the
  # cluster placement. authorize?: false — the system seam (the
  # caller's own authorization already decided this use is licensed).
  defp load_instance(%PocketIdCustody{instance_id: instance_id}) do
    case Ash.get(FluxVale.Infrastructure.Instance, instance_id, authorize?: false) do
      {:ok, instance} -> {:ok, instance}
      # Defensive: the custody row's FK restricts instance deletion —
      # an instance that vanishes mid-call cannot be staged in the
      # sandbox (its destroy would cascade the custody first).
      # coveralls-ignore-next-line
      {:error, _vanishing_instance} = error -> error
    end
  end

  defp read_key(instance, custody) do
    with {:ok, kubeconfig} <- InstanceK8s.kubeconfig_for(instance) do
      case Secret.get_data(
             kubeconfig,
             InstanceK8s.gateway_access_namespace(),
             custody.api_key_secret_ref
           ) do
        {:ok, %{@api_key_data_key => key}} when is_binary(key) and key != "" ->
          {:ok, key}

        {:ok, _malformed} ->
          # The platform is the Secret's only writer (the
          # read_api_credential stance).
          {:error, :api_key_malformed}

        {:error, %Error{reason: :not_found}} ->
          {:error, :no_api_key}

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp record_event(custody, purpose, actor) do
    RecordCustodyEvent.call(%{
      organization_id: custody.organization_id,
      instance_id: custody.instance_id,
      kind: :used,
      purpose: purpose,
      actor_id: actor && actor.id
    })
  end
end
