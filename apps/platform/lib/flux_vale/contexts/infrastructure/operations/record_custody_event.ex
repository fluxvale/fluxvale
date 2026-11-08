defmodule FluxVale.Infrastructure.Operations.RecordCustodyEvent do
  @moduledoc """
  The guarded custody-audit append (#597 S2, the D1 amendment) — the
  ONE write seam behind the custody operations and the key-use seam,
  the Api.RecordAuditEvent posture.

  A failed write is logged and swallowed, never raised, never
  propagated: every caller rides a success path that already happened
  (a key stored, a verification made, a revocation) and an audit
  hiccup must not fail it. Synchronous on purpose: one indexed
  insert, no supervisor, deterministic in tests.

  Rows never carry the key — org, instance, kind, purpose, actor.
  """

  alias FluxVale.Infrastructure.PocketIdCustodyEvent

  require Logger

  @doc """
  Appends one custody event row. Always returns `:ok` — the guard is
  the contract (see the moduledoc).
  """
  @spec call(map()) :: :ok
  def call(attrs) do
    changeset = Ash.Changeset.for_create(PocketIdCustodyEvent, :record, attrs)

    case Ash.create(changeset, authorize?: false) do
      {:ok, _row} ->
        :ok

      {:error, error} ->
        Logger.warning(
          "custody audit write failed for instance=#{attrs[:instance_id]} " <>
            "kind=#{attrs[:kind]}: #{Exception.message(error)}"
        )

        :ok
    end
  end
end
