defmodule FluxVale.Clients.K8s.ErrorTest do
  use ExUnit.Case, async: true

  alias FluxVale.Clients.K8s.Error

  describe "from_response/1" do
    test "maps 404 to :not_found with the API message" do
      error = Error.from_response({:ok, %{status: 404, body: %{"message" => "nope"}}})

      assert %Error{
               reason: :not_found,
               status_code: 404,
               message: "nope",
               details: %{"message" => "nope"}
             } = error
    end

    test "maps 409 to :already_exists" do
      assert %Error{reason: :already_exists, status_code: 409} =
               Error.from_response({:ok, %{status: 409, body: %{}}})
    end

    test "maps SSA 409 ApplyConflict to :conflict, not :already_exists" do
      body = %{"reason" => "ApplyConflict", "message" => "Apply failed with 1 conflict"}

      assert %Error{reason: :conflict, status_code: 409, message: "Apply failed with 1 conflict"} =
               Error.from_response({:ok, %{status: 409, body: body}})
    end

    test "maps 403 to :forbidden" do
      assert %Error{reason: :forbidden, status_code: 403, message: "Access forbidden"} =
               Error.from_response({:ok, %{status: 403, body: %{}}})
    end

    test "maps other 4xx/5xx to :api_error with a status-bearing message" do
      error = Error.from_response({:ok, %{status: 422, body: %{}}})

      assert %Error{
               reason: :api_error,
               status_code: 422,
               message: "Kubernetes API error (HTTP 422)"
             } = error
    end

    test "extracts a status string when message is absent" do
      error = Error.from_response({:ok, %{status: 400, body: %{"status" => "Failure"}}})

      assert %Error{message: "Failure"} = error
    end

    test "raises on 2xx — minting an error from success is a caller bug" do
      assert_raise ArgumentError, ~r/2xx/, fn ->
        Error.from_response({:ok, %{status: 201, body: %{}}})
      end
    end

    test "maps Mint transport errors to :connection_error" do
      error = Error.from_response({:error, %Mint.TransportError{reason: :econnrefused}})

      assert %Error{reason: :connection_error, status_code: nil} = error
    end

    test "maps plain error terms to :connection_error" do
      assert %Error{reason: :connection_error} = Error.from_response({:error, :nxdomain})
    end

    test "maps unknown shapes to :api_error" do
      assert %Error{reason: :api_error, message: msg} = Error.from_response(:wat)
      assert msg =~ "Unknown error"
    end
  end

  describe "constructors" do
    test "invalid_spec/1, validation_error/1, timeout/1, connection_error/1 set their reason" do
      assert %Error{reason: :invalid_spec, message: "m"} = Error.invalid_spec("m")
      assert %Error{reason: :validation_error, message: "m"} = Error.validation_error("m")
      assert %Error{reason: :timeout, message: "m"} = Error.timeout("m")
      assert %Error{reason: :connection_error, message: "m"} = Error.connection_error("m")
      assert %Error{reason: :api_error, status_code: 500} = Error.api_error("m", 500)
    end
  end
end
