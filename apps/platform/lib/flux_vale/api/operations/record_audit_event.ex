defmodule FluxVale.Api.Operations.RecordAuditEvent do
  @moduledoc """
  The guarded audit append (#360 slice 5) — the ONE write seam behind
  the boundary plug and the mint/revoke operations.

  A failed write is logged and swallowed, never raised, never
  propagated: every caller rides a success path that already happened
  (a token minted, a response being sent) and an audit hiccup must
  not fail it — the touch_last_used posture. Synchronous on purpose:
  one indexed insert on the response path, no supervisor whose tasks
  the suite would have to await, deterministic in tests.
  """

  alias FluxVale.Api.AuditEvent

  require Logger

  @doc """
  Appends one audit row. Always returns `:ok` — the guard is the
  contract (see the moduledoc).
  """
  @spec call(map()) :: :ok
  def call(attrs) do
    changeset = Ash.Changeset.for_create(AuditEvent, :record, attrs)

    case Ash.create(changeset, authorize?: false) do
      {:ok, _row} ->
        :ok

      {:error, error} ->
        Logger.warning(
          "audit write failed for token=#{attrs[:personal_access_token_id]} " <>
            "kind=#{attrs[:kind]}: #{Exception.message(error)}"
        )

        :ok
    end
  end
end
