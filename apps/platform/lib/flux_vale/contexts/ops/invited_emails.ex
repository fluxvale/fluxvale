defmodule FluxVale.Ops.InvitedEmails do
  @moduledoc """
  The sanctioned invitation semantics (#478) — `Ops.AccessRules`'s
  posture: every consumer goes through here, nothing reads the table
  ad hoc.

  `allows?/1` answers the gate's question for an ADDRESS. Admitted two
  ways, nothing else: the team bypass (`@fluxvale.com`, structural — no
  row, nothing to manage) or a non-revoked invitation row matching the
  exact address (per-address, never per domain — a second address at an
  invited address's domain is still refused). Case-insensitive in the
  row and in the address alike.
  """

  alias FluxVale.Ops.InvitedEmail

  # Ash.Query.filter is a macro
  require Ash.Query

  # The team bypass: the company's own domain creates freely, no invite
  # and nothing to manage (#478 design §1).
  @team_domain "fluxvale.com"

  @doc """
  Is `address` admitted to create an account? Garbage in, false out —
  the gate never admits an address it cannot parse.
  """
  @spec allows?(String.t() | Ash.CiString.t() | nil) :: boolean()
  def allows?(nil), do: false

  def allows?(address) do
    if team_address?(address) do
      true
    else
      case invited_row(address) do
        %InvitedEmail{revoked_at: nil} -> true
        # A revoked invite admits nothing (revocation is the off switch
        # for NEW sign-ups; existing accounts were never gated by it)
        %InvitedEmail{} -> false
        nil -> false
      end
    end
  end

  defp team_address?(address) do
    address
    |> to_string()
    |> String.downcase()
    |> String.ends_with?("@" <> @team_domain)
  end

  defp invited_row(address) do
    found =
      InvitedEmail
      |> Ash.Query.filter(address == ^to_string(address))
      |> Ash.read_one(authorize?: false)

    case found do
      {:ok, row} ->
        row

      # coveralls-ignore-start - DB read failure mid-provisioning: the
      # caller's other DB arms are the same not-simulatable class
      {:error, _read_failed} ->
        nil
        # coveralls-ignore-stop
    end
  end
end
