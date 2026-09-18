defmodule FluxVale.Clients.K8s.Resources.Secret do
  @moduledoc """
  CRUD operations for Kubernetes Secrets.

  Secrets carry app environment variables. Data is passed as plain strings
  and base64-encoded here — kubereq does not encode it for you.
  """

  alias FluxVale.Clients.K8s.Error

  require Logger

  @typedoc "Secret data map (plain strings, not base64 encoded)"
  @type data :: %{String.t() => String.t()}

  @doc "Creates (server-side-applies) a Secret with the given data."
  @spec create(Kubereq.Kubeconfig.t(), String.t(), String.t(), data()) ::
          {:ok, map()} | {:error, Error.t()}
  def create(kubeconfig, namespace, name, data) do
    req = create_req(kubeconfig)
    manifest = build_manifest(namespace, name, data)

    case Kubereq.apply(req, manifest, "fluxvale") do
      {:ok, %{status: 201, body: body}} ->
        Logger.debug("Created secret: #{namespace}/#{name}")
        {:ok, body}

      {:ok, %{status: 200, body: body}} ->
        Logger.debug("Updated secret: #{namespace}/#{name}")
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.from_response({:ok, %{status: status, body: body}})}

      {:error, error} ->
        {:error, Error.from_response({:error, error})}
    end
  end

  @doc """
  Gets a Secret. Response data values are base64-encoded — use `get_data/3`
  for decoded values.
  """
  @spec get(Kubereq.Kubeconfig.t(), String.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def get(kubeconfig, namespace, name) do
    req = create_req(kubeconfig)

    case Kubereq.get(req, namespace, name) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: 404}} ->
        {:error, Error.from_response({:ok, %{status: 404, body: %{}}})}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.from_response({:ok, %{status: status, body: body}})}

      {:error, error} ->
        {:error, Error.from_response({:error, error})}
    end
  end

  @doc """
  Gets a Secret and decodes the data values. Errors on invalid base64.
  """
  @spec get_data(Kubereq.Kubeconfig.t(), String.t(), String.t()) ::
          {:ok, data()} | {:error, Error.t()}
  def get_data(kubeconfig, namespace, name) do
    case get(kubeconfig, namespace, name) do
      {:ok, secret} ->
        encoded = get_in(secret, ["data"]) || %{}
        decode_data(encoded)

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Decodes base64-encoded secret data. Errors on invalid encoding.
  """
  @spec decode_data(map()) :: {:ok, data()} | {:error, Error.t()}
  def decode_data(encoded_data) do
    Enum.reduce_while(encoded_data, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      decode_single_key(key, value, acc)
    end)
  end

  @doc "Upserts a Secret — SSA, idempotent."
  @spec upsert(Kubereq.Kubeconfig.t(), String.t(), String.t(), data()) ::
          {:ok, map()} | {:error, Error.t()}
  def upsert(kubeconfig, namespace, name, data) do
    create(kubeconfig, namespace, name, data)
  end

  @doc "Deletes a Secret."
  @spec delete(Kubereq.Kubeconfig.t(), String.t(), String.t()) :: :ok | {:error, Error.t()}
  def delete(kubeconfig, namespace, name) do
    req = create_req(kubeconfig)

    case Kubereq.delete(req, namespace, name) do
      {:ok, %{status: 200}} ->
        Logger.debug("Deleted secret: #{namespace}/#{name}")
        :ok

      {:ok, %{status: 202}} ->
        Logger.debug("Secret deletion initiated: #{namespace}/#{name}")
        :ok

      {:ok, %{status: 404}} ->
        {:error, Error.from_response({:ok, %{status: 404, body: %{}}})}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.from_response({:ok, %{status: status, body: body}})}

      {:error, error} ->
        {:error, Error.from_response({:error, error})}
    end
  end

  @doc "Checks secret existence. `{:ok, boolean()}` or `{:error, %Error{}}`."
  @spec exists?(Kubereq.Kubeconfig.t(), String.t(), String.t()) ::
          {:ok, boolean()} | {:error, Error.t()}
  def exists?(kubeconfig, namespace, name) do
    case get(kubeconfig, namespace, name) do
      {:ok, _secret} -> {:ok, true}
      {:error, %Error{reason: :not_found}} -> {:ok, false}
      {:error, error} -> {:error, error}
    end
  end

  @doc "Builds the Opaque Secret manifest — data base64-encoded here."
  @spec build_manifest(String.t(), String.t(), data()) :: map()
  def build_manifest(namespace, name, data) do
    encoded_data = Map.new(data, fn {key, value} -> {key, Base.encode64(value)} end)

    %{
      "apiVersion" => "v1",
      "kind" => "Secret",
      "metadata" => %{
        "name" => name,
        "namespace" => namespace,
        "labels" => %{
          "app.kubernetes.io/managed-by" => "fluxvale",
          "app.kubernetes.io/name" => name
        }
      },
      "type" => "Opaque",
      "data" => encoded_data
    }
  end

  defp decode_single_key(key, value, acc) do
    case Base.decode64(value) do
      {:ok, decoded} ->
        {:cont, {:ok, Map.put(acc, key, decoded)}}

      :error ->
        {:halt, {:error, Error.validation_error("Invalid base64 encoding for key: #{key}")}}
    end
  end

  defp create_req(kubeconfig) do
    Kubereq.attach(Req.new(), kubeconfig: kubeconfig, api_version: "v1", kind: "Secret")
  end
end
