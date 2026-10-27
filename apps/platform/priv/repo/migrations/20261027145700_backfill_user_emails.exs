defmodule FluxVale.Repo.Migrations.BackfillUserEmails do
  @moduledoc """
  Data backfill for `user_emails` (identity lane #285, ADR-0032): every
  existing user gets exactly one row — their sign-in address, already
  verified (it proved itself by code sign-in, so `verified_at` = the
  user's `created_at`) and primary.

  Idempotent: users who already have rows are skipped, so a re-run is
  safe.

  Coverage note: `priv/repo/migrations` is not in coveralls.json's
  skip_files, but migrations are `.exs` loaded by Ecto at runtime — they
  never enter the compiled coverage trace (no existing migration carries
  a coveralls-ignore block), so no exclusion is needed here.
  """

  use Ecto.Migration

  alias FluxVale.Repo

  # from/2 is a macro that cannot be alias-qualified (its pin variables
  # must bind in caller scope) — the sanctioned-import exception.
  import Ecto.Query

  def up do
    # Anti-join = the idempotency guard: only users without rows. Simple
    # pass, ordered by created_at — the table is small, and UUIDv7 is
    # time-ordered so ids run roughly parallel to account age.
    users =
      Repo.all(
        from(u in "users",
          left_join: e in "user_emails",
          on: e.user_id == u.id,
          where: is_nil(e.user_id),
          select: %{id: u.id, email: u.email, created_at: type(u.created_at, :utc_datetime_usec)},
          order_by: u.created_at
        )
      )

    rows =
      for user <- users do
        %{
          # ADR-0032: ids are app-side — there is no DB default to lean
          # on. bingenerate (raw 16 bytes) because insert_all is a raw
          # Ecto write — no Ash type layer to cast the string form.
          id: Ash.UUIDv7.bingenerate(),
          user_id: user.id,
          address: user.email,
          verified_at: DateTime.truncate(user.created_at, :second),
          is_primary: true,
          # the row is an account-history fact: it begins when the
          # account began, not when this migration happened to run
          created_at: user.created_at,
          updated_at: user.created_at
        }
      end

    Repo.insert_all("user_emails", rows)
  end

  def down do
    # No-op: the backfill owns no rows worth distinguishing on rollback —
    # create_user_emails' down drops the table wholesale.
    :ok
  end
end
