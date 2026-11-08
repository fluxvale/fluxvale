defmodule FluxVale.Repo.Migrations.DropUsersEmail do
  @moduledoc """
  The #287 contract step: `users.username` goes NOT NULL and the legacy
  `users.email` column drops — `user_emails` is the only address
  storage from here (invited reservations included; see InvitedEmailRow).

  NO data paths, deliberately: ADR-0013 Am. 1's pre-launch carve-out —
  environments wipe and re-seed rather than carrying expand/contract
  compat. Every account the current code writes carries a username from
  birth (JIT create and :invite both derive one), and every address
  lives in user_emails (signup row or reservation); the mirror-era
  stragglers the old sweep rider planned for are pre-launch shapes the
  wipe absorbs.
  """

  use Ecto.Migration

  def up do
    drop_if_exists(unique_index(:users, [:email], name: "users_unique_email_index"))

    alter table(:users) do
      modify(:username, :text, null: false)
      remove(:email)
    end
  end

  def down do
    # Rollback sanity only (the #478 shape): recreates the column
    # verbatim. On a populated table the NOT NULL re-add refuses —
    # restoring the mirror is a wipe-and-restore operation, not an
    # in-place one (the doctrine above).
    alter table(:users) do
      add(:email, :citext, null: false)
      modify(:username, :text, null: true)
    end

    create(unique_index(:users, [:email], name: "users_unique_email_index"))
  end
end
