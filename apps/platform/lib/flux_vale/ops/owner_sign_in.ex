defmodule FluxVale.Ops.OwnerSignIn do
  @moduledoc """
  Operator path to issue a one-time sign-in code for the platform owner.

  Exists because prod cannot deliver mail (`Swoosh.Adapters.Local`) —
  until a prod mailer lands, a code printed by `bin/owner-signin` is
  the only way an owner signs in. Ops-only: no route, nothing seeded,
  gated to one address — `OWNER_EMAIL`, else the single platform
  admin. The address never comes from argv, a URL, or any
  caller-supplied input.
  """

  alias FluxVale.Identity
  alias FluxVale.Identity.User
  alias FluxVale.Identity.UserEmail

  require Ash.Query
  require Logger

  @doc """
  The owner's address: `OWNER_EMAIL` when set (trimmed), else the
  single platform admin's email. Raises with a count when the fallback
  is ambiguous, telling the operator to set `OWNER_EMAIL`.
  """
  @spec owner_email :: String.t()
  def owner_email do
    case System.get_env("OWNER_EMAIL") do
      nil -> single_admin_email()
      value -> if(String.trim(value) == "", do: single_admin_email(), else: String.trim(value))
    end
  end

  @doc """
  Resolves the owner address and requests a code through
  `FluxVale.Identity.request_auth_code/2`, handing it to `deliver`
  (default: `print_code/2`). Raises an actionable operator message on
  throttle, AccessRule rejection, or delivery failure — the code exists
  only in the printed output, so a re-run is the retry. Logs the address
  and outcome, never the code.

  When `OWNER_EMAIL` does not match the environment's single platform
  admin (a typo), it still issues the code but logs a warning — the
  operator asked for a specific address, so a non-admin session is
  possible and worth naming.
  """
  @spec issue_code((String.t(), String.t() -> {:ok, term()})) :: :ok
  def issue_code(deliver \\ &print_code/2) do
    email = owner_email()

    warn_if_not_admin(email)

    case Identity.request_auth_code(email, deliver) do
      :ok ->
        Logger.info("owner sign-in code issued for #{email}")

        :ok

      {:error, :throttled} ->
        raise "owner sign-in code throttled — one code per address per 60 seconds; wait a minute and re-run"

      {:error, :not_allowed} ->
        raise "owner sign-in code rejected by AccessRule for #{email} — allow the address or set OWNER_EMAIL"

      {:error, reason} ->
        raise "owner sign-in code request failed: #{inspect(reason)}"
    end
  end

  @doc """
  The default deliver: prints the address, the code, the 10-minute
  expiry, and the exact next step to stdout. Returns `{:ok, :printed}`.

  Printed, not logged — the operator's terminal is the delivery channel
  (`eval` runs outside the container's log stream), same posture as the
  smoke PAT script. That is the one deliberate `IO.puts` in `lib/`.
  """
  @spec print_code(String.t(), String.t()) :: {:ok, :printed}
  def print_code(email, code) do
    host = endpoint_host()

    # credo:disable-for-next-line Credo.Check.Refactor.IoPuts
    IO.puts("""
    Owner sign-in code for #{email}: #{code}

    Expires in 10 minutes. Next steps:
      1. open https://#{host}/sign-in
      2. enter the address #{email}
      3. enter the code #{code}
    """)

    {:ok, :printed}
  end

  defp single_admin_email do
    case platform_admins() do
      [%{id: id}] ->
        # The account's primary VERIFIED address rides `user_emails`
        # (#285 T3) — `users.email` is a frozen mirror now.
        case primary_email(id) do
          {:ok, address} ->
            address

          # Only data drift can find nothing here (the create mirror
          # stamps every action-created user a verified primary, #285
          # T3 §5) — an admin with no verified primary has no signable
          # address.
          :none ->
            raise "the platform admin has no verified primary email — set OWNER_EMAIL"
        end

      admins ->
        raise "#{length(admins)} platform admins found (need exactly one) — set OWNER_EMAIL"
    end
  end

  defp primary_email(user_id) do
    found =
      UserEmail
      |> Ash.Query.filter(user_id == ^user_id and is_primary and not is_nil(verified_at))
      |> Ash.read_one!(authorize?: false)

    case found do
      %{address: address} -> {:ok, to_string(address)}
      nil -> :none
    end
  end

  # A typo'd OWNER_EMAIL is a valid-address operator decision (issue for
  # it), but the database may have one admin under a different address —
  # name that mismatch loudly so the operator can spot the typo. No abort:
  # the address the operator named wins. The comparison rides the
  # table-backed primary (#285 T3) — the frozen users.email would warn
  # wrong after a set_primary. Any other admin count (zero, several)
  # carries no single admin to compare against, so it stays silent —
  # `single_admin_email/0` owns those cases.
  defp warn_if_not_admin(email) do
    case platform_admins() do
      [%{id: id}] ->
        warn_unless_primary(id, email)

      _not_exactly_one ->
        :ok
    end
  end

  defp warn_unless_primary(admin_id, email) do
    case primary_email(admin_id) do
      {:ok, admin_email} ->
        if admin_email != email do
          Logger.warning(
            "OWNER_EMAIL #{email} does not match the platform admin #{admin_email} — " <>
              "issuing a code for #{email} anyway (that session will not be an admin)"
          )
        end

      # A drift admin has no signable address to compare against;
      # the named session will not be the admin's either way.
      :none ->
        Logger.warning(
          "OWNER_EMAIL #{email}: the platform admin has no verified primary email — " <>
            "issuing a code for #{email} anyway (that session will not be an admin)"
        )
    end
  end

  defp platform_admins do
    User
    |> Ash.Query.filter(platform_role == :admin)
    |> Ash.read!(authorize?: false)
  end

  # The public host this environment is served on (PHX_HOST, via
  # runtime.exs), so the printed URL is the one the operator can click.
  defp endpoint_host do
    :flux_vale
    |> Application.fetch_env!(FluxValeWeb.Endpoint)
    |> Keyword.fetch!(:url)
    |> Keyword.fetch!(:host)
  end
end
