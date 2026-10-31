defmodule FluxVale.Clients.K8s.Resources.Middleware do
  @moduledoc """
  CRUD operations for Traefik Middleware CRDs (`traefik.io/v1alpha1`)
  — the per-instance edge middlewares of scale-to-zero (#203,
  ADR-0036):

  - `forward_auth`: the activity beacon Traefik consults before every
    forwarded request — the platform's `/internal/edge/touch` marks
    the instance's idle clock; probe user-agents are filtered there.
    This is the "middleware writing per-instance last-used markers"
    the issue settled on (idle detection at the edge, never in-pod).
  - `request_headers`: the wake marker — custom request headers
    stamped on wake-mode routes so the wake endpoint knows which
    instance a visitor asked for without parsing hostnames.
  - `replace_path_regex`: the access edge's wake rewrite (ADR-0040
    §7) — the visitor's path is re-pointed at the platform's
    `/internal/access/<gateway>/<instance>` prefix, the PAIR in the
    path being the whole authorization (#301's contract, carried
    verbatim through the Traefik hop).

  ## Simplified Spec Format

      %{
        forward_auth: %{
          address: "http://fluxvale-platform.fluxvale-dev.svc.cluster.local:4000/internal/edge/touch?instance=<uuid>",
          auth_request_headers: ["User-Agent"]
        }
      }

      %{request_headers: %{"X-FluxVale-Instance" => "<uuid>"}}

      %{replace_path_regex: %{regex: "^/(.*)", replacement: "/internal/access/<gw>/<inst>/$1"}}

  Values are platform-config-derived (never user input); validation is
  fail-loudly defense: an http(s) URL for the beacon address, token
  header names, newline-free header values — a malformed value must
  die at the apply, not route traffic wrong.
  """

  alias FluxVale.Clients.K8s.Error

  require Logger

  @typedoc "Simplified middleware specification"
  @type spec :: %{
          optional(:forward_auth) => %{
            required(:address) => String.t(),
            optional(:auth_request_headers) => [String.t()]
          },
          optional(:request_headers) => %{optional(String.t()) => String.t()},
          optional(:replace_path_regex) => %{
            required(:regex) => String.t(),
            required(:replacement) => String.t()
          }
        }

  @http_url ~r/\Ahttps?:\/\/[^\s`"']+\z/
  # RFC 7230 header token: no separators, no CTLs — and \z, not $
  # (a trailing newline must fail here, not at the API server).
  @header_name ~r/\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/
  @header_value ~r/\A[^\r\n]*\z/

  @doc "Creates (server-side-applies) a Middleware."
  @spec create(Kubereq.Kubeconfig.t(), String.t(), String.t(), spec()) ::
          {:ok, map()} | {:error, Error.t()}
  def create(kubeconfig, namespace, name, spec) do
    case validate(spec) do
      :ok ->
        do_create(kubeconfig, namespace, name, spec)

      {:error, message} ->
        {:error, Error.invalid_spec(message)}
    end
  end

  defp do_create(kubeconfig, namespace, name, spec) do
    req = create_req(kubeconfig)
    manifest = build_manifest(namespace, name, spec)

    case Kubereq.apply(req, manifest, "fluxvale") do
      {:ok, %{status: 201, body: body}} ->
        Logger.debug("Created middleware: #{namespace}/#{name}")
        {:ok, body}

      {:ok, %{status: 200, body: body}} ->
        Logger.debug("Updated middleware: #{namespace}/#{name}")
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.from_response({:ok, %{status: status, body: body}})}

      {:error, error} ->
        {:error, Error.from_response({:error, error})}
    end
  end

  @doc "Deletes a Middleware."
  @spec delete(Kubereq.Kubeconfig.t(), String.t(), String.t()) :: :ok | {:error, Error.t()}
  def delete(kubeconfig, namespace, name) do
    req = create_req(kubeconfig)

    case Kubereq.delete(req, namespace, name) do
      {:ok, %{status: status}} when status in [200, 202] ->
        Logger.debug("Deleted middleware: #{namespace}/#{name}")
        :ok

      {:ok, %{status: status, body: body}} ->
        {:error, Error.from_response({:ok, %{status: status, body: body}})}

      {:error, error} ->
        {:error, Error.from_response({:error, error})}
    end
  end

  @doc """
  Builds the Middleware manifest from the simplified spec. Exactly one
  strategy key per object — beacon and marker are separate
  Middlewares on separate routes.
  """
  @spec build_manifest(String.t(), String.t(), spec()) :: map()
  def build_manifest(namespace, name, spec) do
    spec_body =
      cond do
        Map.has_key?(spec, :forward_auth) ->
          auth = spec.forward_auth

          %{
            "forwardAuth" => %{
              "address" => auth.address,
              "authRequestHeaders" => Map.get(auth, :auth_request_headers, [])
            }
          }

        Map.has_key?(spec, :request_headers) ->
          %{"headers" => %{"customRequestHeaders" => spec.request_headers}}

        Map.has_key?(spec, :replace_path_regex) ->
          rewrite = spec.replace_path_regex

          %{
            "replacePathRegex" => %{
              "regex" => rewrite.regex,
              "replacement" => rewrite.replacement
            }
          }

        true ->
          %{}
      end

    %{
      "apiVersion" => "traefik.io/v1alpha1",
      "kind" => "Middleware",
      "metadata" => %{
        "name" => name,
        "namespace" => namespace,
        "labels" => %{
          "app.kubernetes.io/managed-by" => "fluxvale",
          "app.kubernetes.io/name" => name
        }
      },
      "spec" => spec_body
    }
  end

  defp validate(spec) do
    strategies =
      Enum.count([:forward_auth, :request_headers, :replace_path_regex], &Map.has_key?(spec, &1))

    cond do
      strategies > 1 ->
        # Exactly one strategy per object — a multi-key spec would
        # silently drop all but one from the manifest.
        {:error,
         "middleware spec takes exactly one of forward_auth, request_headers, replace_path_regex"}

      Map.has_key?(spec, :forward_auth) ->
        validate_forward_auth(spec.forward_auth)

      Map.has_key?(spec, :request_headers) ->
        validate_request_headers(spec.request_headers)

      Map.has_key?(spec, :replace_path_regex) ->
        validate_replace_path_regex(spec.replace_path_regex)

      true ->
        {:error, "middleware spec needs forward_auth, request_headers, or replace_path_regex"}
    end
  end

  defp validate_forward_auth(auth) do
    address = Map.get(auth, :address)
    header_names = Map.get(auth, :auth_request_headers, [])

    cond do
      not is_binary(address) or not Regex.match?(@http_url, address) ->
        {:error, "forwardAuth address must be an http(s) URL: #{inspect(address)}"}

      not Enum.all?(header_names, &Regex.match?(@header_name, &1)) ->
        {:error, "forwardAuth auth_request_headers must be valid header names"}

      true ->
        :ok
    end
  end

  defp validate_request_headers(headers) do
    names = Map.keys(headers)
    values = Map.values(headers)

    names_ok? = Enum.all?(names, &Regex.match?(@header_name, &1))
    values_ok? = Enum.all?(values, &Regex.match?(@header_value, &1))

    cond do
      not names_ok? -> {:error, "request header names must be RFC 7230 tokens"}
      not values_ok? -> {:error, "request header values must be single-line"}
      true -> :ok
    end
  end

  # Both halves are required and non-empty: a missing regex or an empty
  # replacement would apply a rewrite that sends every request to the
  # same dead path — a malformed value must die at the apply, not route
  # traffic wrong.
  defp validate_replace_path_regex(rewrite) do
    cond do
      not is_binary(rewrite[:regex]) or rewrite[:regex] == "" ->
        {:error, "replace_path_regex needs a non-empty regex"}

      not is_binary(rewrite[:replacement]) or rewrite[:replacement] == "" ->
        {:error, "replace_path_regex needs a non-empty replacement"}

      true ->
        :ok
    end
  end

  defp create_req(kubeconfig) do
    Kubereq.attach(Req.new(),
      kubeconfig: kubeconfig,
      api_version: "traefik.io/v1alpha1",
      kind: "Middleware"
    )
  end
end
