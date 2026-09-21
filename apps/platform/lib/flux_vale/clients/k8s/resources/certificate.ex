defmodule FluxVale.Clients.K8s.Resources.Certificate do
  @moduledoc """
  CRUD operations for cert-manager `Certificate` CRDs.

  Custom-domain surface — deferred post-beta (ADR-0031), ported now because
  it ships with the client's correctness story (Ready-condition reading).
  When it goes live: per-domain certs use HTTP-01 (we don't control the
  user's DNS), the platform wildcard uses DNS-01.

  ## Simplified Spec Format

      %{
        domain: "myapp.example.com",             # Required: DNS name to certify
        secret_name: "myapp-example-com-tls",    # Required: Secret cert-manager writes to
        issuer: "letsencrypt-production-http01", # Required: Issuer resource name (free-form)
        issuer_kind: :cluster_issuer             # Optional (default :cluster_issuer)
      }
  """

  alias FluxVale.Clients.K8s.Error

  require Logger

  @typedoc """
  cert-manager's issuerRef.kind — the only two kinds it recognizes.
  `:cluster_issuer` is cluster-scoped (referenced from any namespace);
  `:issuer` is namespace-scoped (must live alongside the Certificate).
  """
  @type issuer_kind :: :cluster_issuer | :issuer

  @default_issuer_kind :cluster_issuer

  @issuer_kinds %{
    cluster_issuer: "ClusterIssuer",
    issuer: "Issuer"
  }

  @typedoc "Simplified certificate specification"
  @type spec :: %{
          required(:domain) => String.t(),
          required(:secret_name) => String.t(),
          required(:issuer) => String.t(),
          optional(:issuer_kind) => issuer_kind()
        }

  @doc """
  Creates (server-side-applies) a Certificate CRD.

  Rejects an unknown `:issuer_kind` up front (`{:error, :invalid_spec}`) —
  cert-manager would otherwise leave a mistyped Certificate pending forever.
  """
  @spec create(Kubereq.Kubeconfig.t(), String.t(), String.t(), spec()) ::
          {:ok, map()} | {:error, Error.t()}
  def create(kubeconfig, namespace, name, spec) do
    kind = Map.get(spec, :issuer_kind, @default_issuer_kind)

    if Map.has_key?(@issuer_kinds, kind) do
      do_create(kubeconfig, namespace, name, spec)
    else
      {:error,
       Error.invalid_spec(
         "Unknown issuer_kind: #{inspect(kind)} — expected :cluster_issuer or :issuer"
       )}
    end
  end

  defp do_create(kubeconfig, namespace, name, spec) do
    req = create_req(kubeconfig)
    manifest = build_manifest(namespace, name, spec)

    case Kubereq.apply(req, manifest, "fluxvale") do
      {:ok, %{status: 201, body: body}} ->
        Logger.debug("Created certificate: #{namespace}/#{name}")
        {:ok, body}

      {:ok, %{status: 200, body: body}} ->
        Logger.debug("Updated certificate: #{namespace}/#{name}")
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.from_response({:ok, %{status: status, body: body}})}

      {:error, error} ->
        {:error, Error.from_response({:error, error})}
    end
  end

  @doc "Gets a Certificate by namespace and name."
  @spec get(Kubereq.Kubeconfig.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def get(kubeconfig, namespace, name) do
    req = create_req(kubeconfig)

    case Kubereq.get(req, namespace, name) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: 404, body: body}} ->
        {:error, Error.from_response({:ok, %{status: 404, body: body}})}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.from_response({:ok, %{status: status, body: body}})}

      {:error, error} ->
        {:error, Error.from_response({:error, error})}
    end
  end

  @doc "Deletes a Certificate."
  @spec delete(Kubereq.Kubeconfig.t(), String.t(), String.t()) :: :ok | {:error, Error.t()}
  def delete(kubeconfig, namespace, name) do
    req = create_req(kubeconfig)

    case Kubereq.delete(req, namespace, name) do
      {:ok, %{status: 200}} ->
        Logger.debug("Deleted certificate: #{namespace}/#{name}")
        :ok

      {:ok, %{status: 202}} ->
        Logger.debug("Certificate deletion initiated: #{namespace}/#{name}")
        :ok

      {:ok, %{status: 404, body: body}} ->
        {:error, Error.from_response({:ok, %{status: 404, body: body}})}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.from_response({:ok, %{status: status, body: body}})}

      {:error, error} ->
        {:error, Error.from_response({:error, error})}
    end
  end

  @doc """
  Returns the Ready condition status (`"True"` / `"False"` / `nil`).

  cert-manager sets `.status.conditions[].type == "Ready"` — the
  reconciliation signal for cert-gated transitions.
  """
  @spec ready_status(Kubereq.Kubeconfig.t(), String.t(), String.t()) ::
          {:ok, String.t() | nil} | {:error, Error.t()}
  def ready_status(kubeconfig, namespace, name) do
    case get(kubeconfig, namespace, name) do
      {:ok, %{"status" => %{"conditions" => conditions}}} when is_list(conditions) ->
        {:ok, find_ready(conditions)}

      {:ok, _no_status} ->
        {:ok, nil}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc "Builds the Certificate manifest from the simplified spec."
  @spec build_manifest(String.t(), String.t(), spec()) :: map()
  def build_manifest(namespace, name, spec) do
    kind = Map.get(spec, :issuer_kind, @default_issuer_kind)

    %{
      "apiVersion" => "cert-manager.io/v1",
      "kind" => "Certificate",
      "metadata" => %{
        "name" => name,
        "namespace" => namespace,
        "labels" => %{
          "app.kubernetes.io/managed-by" => "fluxvale",
          "app.kubernetes.io/name" => name
        }
      },
      "spec" => %{
        "secretName" => spec.secret_name,
        "issuerRef" => %{
          "name" => spec.issuer,
          "kind" => Map.fetch!(@issuer_kinds, kind)
        },
        "dnsNames" => [spec.domain]
      }
    }
  end

  @doc """
  Extracts the Ready condition status from a cert-manager conditions list —
  `"True"` / `"False"` / `nil` (absent or malformed).
  """
  @spec find_ready(list(map())) :: String.t() | nil
  def find_ready(conditions) do
    case Enum.find(conditions, fn c -> c["type"] == "Ready" end) do
      %{"status" => status} when is_binary(status) -> status
      _other -> nil
    end
  end

  defp create_req(kubeconfig) do
    Kubereq.attach(Req.new(),
      kubeconfig: kubeconfig,
      api_version: "cert-manager.io/v1",
      kind: "Certificate"
    )
  end
end
