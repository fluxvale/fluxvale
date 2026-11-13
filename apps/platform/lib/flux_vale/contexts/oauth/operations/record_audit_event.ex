defmodule FluxVale.OAuth.Operations.RecordAuditEvent do
  @moduledoc """
  The guarded OAuth audit append (#766) — the ONE write seam behind
  registration, consent, code, and token lifecycle events.

  A failed write is logged and swallowed, never raised: every caller
  rides a success path that already happened, and an audit hiccup must
  not fail a registered client or an issued token (the ApiAudit
  posture).
  """

  alias FluxVale.OAuth.AuditEvent

  require Logger

  @doc """
  Appends one OAuth audit row. Always returns `:ok`.
  """
  @spec call(map()) :: :ok
  def call(attrs) do
    changeset = Ash.Changeset.for_create(AuditEvent, :record, attrs)

    case Ash.create(changeset, authorize?: false) do
      {:ok, _row} ->
        :ok

      {:error, error} ->
        Logger.warning(
          "OAuth audit write failed kind=#{attrs[:kind]}: #{Exception.message(error)}"
        )

        :ok
    end
  end
end
