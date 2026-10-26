defmodule FluxVale.Infrastructure.AccessProvider do
  @moduledoc """
  The access-provider boundary (ADR-0039 §2, the seam #265 promised): the
  verbs that make a `private` instance reachable, with no provider
  vocabulary above this module.

  Billing, wake, the panel and the instance lifecycle call these and
  never branch on `gateway.provider` — a WireGuard gateway adds an enum
  value, an implementation module and one `impl_for/1` arm. Route keys
  stay opaque (`AccessRoute.route_key`), so a swap needs no migration.

  The Tailscale implementation is `FluxVale.Infrastructure.AccessProviders.Tailscale`.
  """

  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessRoute
  alias FluxVale.Infrastructure.Instance

  @typedoc """
  What `gateway_status/1` observes. `:active` means the pod is running
  AND on the tailnet; `:needs_attention` means it is not, with copy the
  panel can render; `:provisioning` means the objects are landing.
  """
  @type status :: %{state: :active | :needs_attention | :provisioning, message: String.t()}

  @doc """
  Creates (or converges) the gateway's cluster objects: the credential
  Secret, the persisted-state PVC, the serve-config Secret and the
  Deployment. Idempotent (SSA) — re-running is the recovery path.

  Returns `%{credential_secret_ref: String.t()}` — the Secret's NAME
  (never the key), which the row records so a reader can locate the
  credential without knowing the provider's naming rule.

  A failure leaves the Secret in place deliberately: `:provision`'s drift
  repair reads its key from there, so a transient failure must stay
  repairable.
  """
  @callback provision_gateway(AccessGateway.t(), String.t()) ::
              {:ok, %{credential_secret_ref: String.t()}} | {:error, term()}

  @doc """
  Allocates a provider route for the instance and applies it: the serve
  config gains the instance's port and the instance's private
  NetworkPolicy admits the gateway's namespace. Returns the route.
  """
  @callback attach_instance(AccessGateway.t(), Instance.t()) ::
              {:ok, AccessRoute.t()} | {:error, term()}

  @doc """
  The mirror: removes the route's serve entry and the policy's gateway
  entry, then deletes the row. Idempotent — a missing route is success.
  """
  @callback detach_instance(AccessGateway.t(), Instance.t()) :: :ok | {:error, term()}

  @doc """
  Observes the gateway's state from the cluster (read-only).
  """
  @callback gateway_status(AccessGateway.t()) :: {:ok, status()} | {:error, term()}

  @doc """
  Puts a freshly-woken instance back on the gateway's routes: rewrites
  the serve config's target for the instance's port from the wake
  endpoint to the app Service. Called by the wake endpoint once the
  instance reports `:running` (ADR-0039 §6).
  """
  @callback wake_intercept(AccessGateway.t(), Instance.t()) :: {:ok, term()} | {:error, term()}

  @doc """
  Writes the auth key to the gateway's Secret and restarts the pod so it
  joins under the new key (the re-paste recovery, ADR-0039 §4).
  """
  @callback update_credential(AccessGateway.t(), String.t()) :: :ok | {:error, term()}

  @doc """
  Reads the auth key back from the gateway's Secret — **internal only**,
  for the provisioning retry (the trigger has no create argument). No
  user surface calls this: the panel's rule is that a key goes in and
  never comes out (ADR-0039 §4).
  """
  @callback read_credential(AccessGateway.t()) :: {:ok, String.t()} | {:error, term()}

  @doc """
  Scales the gateway pod to `replicas` (0 = the zero-balance ladder's
  suspension; 1 = the owner's resume). The Secret, PVC and serve config
  stay in both directions so a resume is cheap and a suspension loses no
  identity (ADR-0039 §5).
  """
  @callback scale_gateway(AccessGateway.t(), non_neg_integer()) :: :ok | {:error, term()}

  @doc """
  Deletes every cluster object the gateway owns. The caller deletes the
  row after this succeeds; the Secret and PVC go here (a suspended
  gateway keeps them, a destroyed one does not).
  """
  @callback teardown_gateway(AccessGateway.t()) :: :ok | {:error, term()}

  @doc """
  Removes the objects a FAILED `create` left behind — the rollback half,
  called only when the row is about to disappear.

  Deliberately separate from `provision_gateway/2`: that one must never
  clean up after itself, because `:provision`'s drift repair re-reads its
  key from the very Secret it wrote. A failed create, by contrast, leaves
  no row at all (the create transaction rolls back), so anything still in
  the cluster is ungoverned — a live tailnet key and a PVC nobody owns.
  """
  @callback cleanup_failed_provision(AccessGateway.t()) :: :ok | {:error, term()}

  @doc """
  The provider implementation for a gateway — the one dispatch point.
  """
  @spec impl_for(AccessGateway.t()) :: module()
  def impl_for(%AccessGateway{provider: :tailscale}),
    do: FluxVale.Infrastructure.AccessProviders.Tailscale
end
