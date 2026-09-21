defmodule FluxVale.Clients.K8s.Resources.SecretTest do
  use ExUnit.Case, async: true

  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Secret

  describe "build_manifest/3" do
    test "base64-encodes plain data values (kubereq does not)" do
      manifest = Secret.build_manifest("ns", "app-env", %{"API_KEY" => "s3cr3t"})

      assert manifest["kind"] == "Secret"
      assert manifest["type"] == "Opaque"
      assert manifest["data"] == %{"API_KEY" => Base.encode64("s3cr3t")}
    end
  end

  describe "decode_data/1" do
    test "decodes base64 values — the get_data payload path" do
      encoded = %{"API_KEY" => Base.encode64("s3cr3t")}

      assert Secret.decode_data(encoded) == {:ok, %{"API_KEY" => "s3cr3t"}}
    end

    test "errors on invalid base64 (the only validation_error consumer)" do
      assert {:error, %Error{reason: :validation_error, message: msg}} =
               Secret.decode_data(%{"BAD" => "not-base64!!"})

      assert msg =~ "BAD"
    end
  end
end
