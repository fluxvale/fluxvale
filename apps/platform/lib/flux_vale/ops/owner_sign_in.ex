defmodule FluxVale.Ops.OwnerSignIn do
  @moduledoc """
  Operator path to issue a one-time sign-in code for the platform owner.

  Exists because prod cannot deliver mail (`Swoosh.Adapters.Local`) —
  until a prod mailer lands, a code printed by `bin/owner-signin` is
  the only way an owner signs in. Ops-only: no route, nothing seeded,
  gated to one address — `OWNER_EMAIL`, else the single platform
  admin. The address never comes from argv, a URL, or any
  caller-supplied input.

  Invited-unaccepted owners (#502) can neither receive the invite mail
  (prod cannot deliver) nor pass the code wall (:invite_pending) — for
  those, `issue_code` re-invites instead (the InviteUser reinvite path)
  and prints the one-time accept link. Printing re-mints: the previous
  link dies. An address with no account and no team-domain claim
  raises actionable — invite it first.
  """

  alias FluxVale.Identity
  alias FluxVale.Identity.User
  alias FluxVale.Identity.UserEmail

  require Ash.Query
  require Logger

  # The team bypass's domain — owned here outright (the
  # VerifyAuthCode posture): a userless address on the team domain
  # rides the code path (the JIT create admits it); anything else with
  # no account is an actionable raise.
  @team_domain "fluxvale.com"

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
  Resolves the owner address and issues what the address can consume
  (#502): an invited-unaccepted account gets a re-invite with the
  accept link printed (`print_accept_url/2` — printing re-mints, the
  previous link dies); an active account, or a userless team-domain
  address, gets a code through `FluxVale.Identity.request_auth_code/2`
  handed to `deliver` (default: `print_code/2`). Raises an actionable
  operator message on throttle, AccessRule rejection, delivery
  failure, or an uninvitable address — the code exists only in the
  printed output, so a re-run is the retry. Logs the address and
  outcome, never the code or the token.

  When `OWNER_EMAIL` does not match the environment's single platform
  admin (a typo), it still issues but logs a warning — the operator
  asked for a specific address, so a non-admin session is possible and
  worth naming.
  """
  @spec issue_code((String.t(), String.t() -> {:ok, term()})) :: :ok
  def issue_code(deliver \\ &print_code/2) do
    email = owner_email()

    warn_if_not_admin(email)
    arm(email, deliver)
  end

  # The break-glass fork (#502). Occupant resolution reads BOTH
  # identity surfaces, authorize?: false with a comment — the same
  # system seam InviteUser's lookup runs (an operator task has no
  # actor, and the read leaks nothing the printed output doesn't
  # already carry).
  defp arm(email, deliver) do
    case resolve_occupant(email) do
      {:ok, %User{invite_state: state}} when state in [:pending, :withdrawn, :expired] ->
        reinvite_and_print(email)

      {:ok, %User{}} ->
        code_arm(email, deliver)

      :none ->
        team_or_raise(email, deliver)
    end
  end

  defp reinvite_and_print(email) do
    # authorize?: false is acceptable here: operator-trusted
    # break-glass (bin/owner-signin), never caller input. The deliver
    # is deliberately print_accept_url — the terminal is the delivery
    # channel, exactly like print_code.
    case Identity.invite_user(nil, email, &print_accept_url/2, authorize?: false) do
      {:ok, _user, _raw} ->
        Logger.warning(
          "owner invite re-issued for #{email}: printing re-mints the accept link, " <>
            "the previous link is dead"
        )

        :ok

      # coveralls-ignore-start - race-only: the reinvite write refuses
      # (StaleRecord / :already_active) only if the invite is accepted or
      # retired between the occupant read and the write — true
      # concurrency; every sequential shape routes to an arm above
      {:error, reason} ->
        raise "owner invite re-issue failed for #{email}: #{inspect(reason)}"
        # coveralls-ignore-stop
    end
  end

  defp code_arm(email, deliver) do
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

  # A userless address rides the code path only when the JIT create
  # would admit it (the team bypass). Anything else raises BEFORE a
  # code burns: the code wall would refuse with :invitation_required
  # anyway, so name the invite lever instead.
  defp team_or_raise(email, deliver) do
    if team_address?(email) do
      code_arm(email, deliver)
    else
      raise(
        "no account exists for #{email} and it is outside the team domain " <>
          "(#{@team_domain}). Invite it first via FluxVale.Identity.invite_user/2, " <>
          "then re-run"
      )
    end
  end

  # Case-insensitive exact-suffix match (the VerifyAuthCode shape —
  # each operation owns its constants and helpers outright).
  defp team_address?(address) do
    downcased =
      address
      |> to_string()
      |> String.downcase()

    String.ends_with?(downcased, "@" <> @team_domain)
  end

  # Both identity surfaces (the InviteUser posture): a verified
  # user_emails row resolves its owner, the frozen users.email mirror
  # resolves an invited-unaccepted account (no verified row yet).
  defp resolve_occupant(email) do
    with {:ok, nil} <- verified_row_owner(email),
         {:ok, nil} <- frozen_mirror_owner(email) do
      :none
    else
      {:ok, %User{} = user} ->
        {:ok, user}

      # coveralls-ignore-start - DB read failure mid-lookup: the same
      # not-simulatable class as the other DB-down arms here
      {:error, _read_failed} ->
        raise "owner address lookup failed for #{email}"
        # coveralls-ignore-stop
    end
  end

  defp verified_row_owner(email) do
    User
    |> Ash.Query.for_read(:get_by_email, %{email: email})
    |> Ash.Query.load(:invite_state)
    |> Ash.read_one(authorize?: false)
  end

  defp frozen_mirror_owner(email) do
    User
    |> Ash.Query.filter(email == ^email)
    |> Ash.Query.load(:invite_state)
    |> Ash.read_one(authorize?: false)
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

  @doc """
  The invited owner's default deliver (#502): prints the address, the
  one-time accept link, the expiry, and the fact that printing re-minted
  the invite — the previous link is dead. Same posture as print_code/2:
  printed to the operator's terminal, never logged (the terminal is the
  delivery channel; the URL carries the credential).
  """
  @spec print_accept_url(String.t(), String.t()) :: {:ok, :printed}
  def print_accept_url(email, accept_url) do
    days = User.invite_ttl_days()

    # credo:disable-for-next-line Credo.Check.Refactor.IoPuts
    IO.puts("""
    Accept link for #{email}: #{accept_url}

    The link expires in #{days} days and works once. This link replaced the earlier one: the previous link is dead. Next steps:
      1. open the link in a browser
      2. the account activates and signs in straight away
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
