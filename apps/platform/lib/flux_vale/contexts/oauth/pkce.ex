defmodule FluxVale.OAuth.PKCE do
  @moduledoc """
  PKCE S256 verification (#766, RFC 7636): every client is public, so
  every authorization request must carry a challenge and every token
  request its verifier.

  Only `S256` is accepted — `plain` and missing methods are refused at
  the authorization endpoint. Challenges are the 43-character base64url
  SHA-256 digest; verifiers are 43–128 unreserved characters. The
  comparison is constant-time.
  """

  @verifier_format ~r/\A[A-Za-z0-9\-._~]{43,128}\z/
  @challenge_format ~r/\A[A-Za-z0-9\-_]{43}\z/

  @doc "Is this a valid S256 challenge (the value the client sends)?"
  @spec valid_challenge?(term(), term()) :: boolean()
  def valid_challenge?(challenge, "S256") when is_binary(challenge) do
    Regex.match?(@challenge_format, challenge)
  end

  def valid_challenge?(_challenge, _method), do: false

  @doc "Does `verifier` hash to `challenge`? Constant-time."
  @spec verify(term(), term()) :: boolean()
  def verify(verifier, challenge) when is_binary(verifier) and is_binary(challenge) do
    if Regex.match?(@verifier_format, verifier) do
      computed =
        :sha256
        |> :crypto.hash(verifier)
        |> Base.url_encode64(padding: false)

      Plug.Crypto.secure_compare(computed, challenge)
    else
      false
    end
  end

  def verify(_verifier, _challenge), do: false
end
