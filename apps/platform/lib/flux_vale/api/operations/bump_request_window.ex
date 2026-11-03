defmodule FluxVale.Api.Operations.BumpRequestWindow do
  @moduledoc """
  Upsert-increments a token's fixed-window counter — one atomic
  statement, the per-request write behind the API rate limit (#360
  slice 3, ADR-0019 §4).

  Raw SQL on purpose (the boundary-module escape hatch, with the
  evidence): ash_postgres 2.13 implements upserts as MERGE on PG17+,
  and MERGE's `WHEN NOT MATCHED` INSERT races — two concurrent
  first-writers on one `{token, window}` both see no match, and the
  loser surfaces the unique violation instead of the increment (the
  concurrency suite proved it: "token_id: has already been taken").
  The ON CONFLICT fallback, in turn, can only SET a column to
  `COALESCE(EXCLUDED.col, default)` — the new row's value — never
  `count = count + 1` (data_layer.ex `upsert_set/4`). Plain
  `INSERT … ON CONFLICT DO UPDATE` is the one statement whose arbiter
  semantics make the increment race-safe: a concurrent first-writer
  blocks, then takes the UPDATE arm. No read-modify-write anywhere.
  """

  alias FluxVale.Repo

  @bump_sql """
  INSERT INTO request_windows (id, token_id, window_started_at, count, created_at, updated_at)
  VALUES ($1, $2, $3, 1, now(), now())
  ON CONFLICT (token_id, window_started_at)
  DO UPDATE SET count = request_windows.count + 1, updated_at = now()
  RETURNING count
  """

  @doc """
  Counts one request for `token_id` in the window starting at
  `window_started_at`, returning the window's new total `count`.

  System write from the boundary plug — no actor to authorize (the
  Authenticate plug's lookup posture). Raises on DB failure: an
  uncounted request must not proceed silently, and the call is
  DB-backed anyway.
  """
  @spec call(String.t(), DateTime.t()) :: pos_integer()
  def call(token_id, window_started_at) do
    result =
      Repo.query!(@bump_sql, [
        Ecto.UUID.dump!(Ash.UUIDv7.generate()),
        Ecto.UUID.dump!(token_id),
        DateTime.to_naive(window_started_at)
      ])

    [[count]] = result.rows
    count
  end
end
