defmodule FluxVale.OAuth.AuditKind do
  @moduledoc """
  What an OAuth audit row records (#766): the authorization server's
  lifecycle events that have no token row to hang off yet.

  Token lifecycle events (mint/revoke) ride `FluxVale.Api.AuditEvent`'s
  existing kinds — an OAuth access token is a token row like any other.
  These are the AS-specific events: client registration, the consent
  decision, code issuance, refresh-reuse detection, and the connection
  disconnect.
  """

  use Ash.Type.Enum,
    values: [
      :client_registered,
      :authorize_approved,
      :authorize_denied,
      :code_issued,
      :code_reuse,
      :token_issued,
      :token_refreshed,
      :refresh_reuse,
      :token_revoked,
      :connection_revoked
    ]
end
