defmodule FluxVale.Api do
  @moduledoc """
  The machine-API boundary domain (#360): per-token request-window
  metering — the store behind `/api/v1` rate limiting (ADR-0019 §4) —
  and the append-only audit trail (slice 5: one row per
  PAT-authenticated call plus mint/revoke events, never the token
  value).

  The boundary's other concern, scopes, stays in `FluxVale.Api.Scopes`
  (a plain module — unchanged). This domain's rows are system-only
  (`authorize?: false` callers — the boundary plug and the janitor),
  never actor-authorizable.
  """

  use Ash.Domain, otp_app: :flux_vale

  resources do
    resource(FluxVale.Api.AuditEvent)
    resource(FluxVale.Api.RequestWindow)
  end

  # System-only operations (verb modules under operations/, the
  # contexts' shape) — the domain stays the public seam.
  defdelegate record_audit_event(attrs),
    to: FluxVale.Api.Operations.RecordAuditEvent,
    as: :call

  defdelegate bump_request_window(token_id, window_started_at),
    to: FluxVale.Api.Operations.BumpRequestWindow,
    as: :call

  defdelegate prune_request_windows(opts \\ []),
    to: FluxVale.Api.Operations.PruneRequestWindows,
    as: :call

  defdelegate prune_audit_events(opts \\ []),
    to: FluxVale.Api.Operations.PruneAuditEvents,
    as: :call
end
