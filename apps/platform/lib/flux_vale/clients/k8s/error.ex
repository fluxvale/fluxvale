defmodule FluxVale.Clients.K8s.Error do
  @moduledoc """
  Structured error for Kubernetes API failures.

  All K8s resource modules return `{:ok, result} | {:error, %Error{}}` —
  one consistent shape across the client layer.
  """

  defstruct [:status_code, :message, :reason, :details]

  @type t :: %__MODULE__{
          status_code: pos_integer() | nil,
          message: String.t(),
          reason: atom(),
          details: map() | nil
        }

  @type reason ::
          :not_found
          | :already_exists
          | :conflict
          | :forbidden
          | :connection_error
          | :api_error
          | :timeout
          | :invalid_spec
          | :validation_error

  @doc """
  Creates an Error from an HTTP response or error tuple.
  """
  @spec from_response(term()) :: t()
  def from_response({:ok, %{status: 404, body: body}}) do
    %__MODULE__{
      status_code: 404,
      reason: :not_found,
      message: extract_message(body) || "Resource not found",
      details: body
    }
  end

  def from_response({:ok, %{status: 409, body: %{"reason" => "ApplyConflict"} = body}}) do
    %__MODULE__{
      status_code: 409,
      reason: :conflict,
      message: extract_message(body) || "Server-side apply conflict",
      details: body
    }
  end

  def from_response({:ok, %{status: 409, body: body}}) do
    %__MODULE__{
      status_code: 409,
      reason: :already_exists,
      message: extract_message(body) || "Resource already exists",
      details: body
    }
  end

  def from_response({:ok, %{status: 403, body: body}}) do
    %__MODULE__{
      status_code: 403,
      reason: :forbidden,
      message: extract_message(body) || "Access forbidden",
      details: body
    }
  end

  def from_response({:ok, %{status: status, body: body}}) when status >= 400 do
    %__MODULE__{
      status_code: status,
      reason: :api_error,
      message: extract_message(body) || "Kubernetes API error (HTTP #{status})",
      details: body
    }
  end

  # 2xx responses are a caller bug — fail loudly rather than mint an error.
  def from_response({:ok, %{status: status}}) when status < 300 do
    raise ArgumentError,
          "from_response/1 should not be called with successful (2xx) responses. " <>
            "Status: #{status}. Check the response status before calling this function."
  end

  def from_response({:error, %Mint.TransportError{reason: reason}}) do
    %__MODULE__{
      status_code: nil,
      reason: :connection_error,
      message: "Connection error: #{inspect(reason)}",
      details: %{transport_error: reason}
    }
  end

  def from_response({:error, reason}) do
    %__MODULE__{
      status_code: nil,
      reason: :connection_error,
      message: "Connection error: #{inspect(reason)}",
      details: %{error: reason}
    }
  end

  def from_response(error) do
    %__MODULE__{
      status_code: nil,
      reason: :api_error,
      message: "Unknown error: #{inspect(error)}",
      details: %{error: error}
    }
  end

  @doc "Creates an error for an invalid spec."
  @spec invalid_spec(String.t()) :: t()
  def invalid_spec(message) do
    %__MODULE__{status_code: nil, reason: :invalid_spec, message: message, details: nil}
  end

  @doc "Creates a validation error."
  @spec validation_error(String.t()) :: t()
  def validation_error(message) do
    %__MODULE__{status_code: nil, reason: :validation_error, message: message, details: nil}
  end

  @doc "Creates a timeout error."
  @spec timeout(String.t()) :: t()
  def timeout(message) do
    %__MODULE__{status_code: nil, reason: :timeout, message: message, details: nil}
  end

  @doc "Creates a connection error."
  @spec connection_error(String.t()) :: t()
  def connection_error(message) do
    %__MODULE__{status_code: nil, reason: :connection_error, message: message, details: nil}
  end

  @doc "Creates an API error with optional status code."
  @spec api_error(String.t(), pos_integer() | nil) :: t()
  def api_error(message, status_code \\ nil) do
    %__MODULE__{status_code: status_code, reason: :api_error, message: message, details: nil}
  end

  defp extract_message(%{"message" => message}) when is_binary(message), do: message
  defp extract_message(%{"status" => status}) when is_binary(status), do: status
  defp extract_message(_other), do: nil
end
