defmodule FluxVale.Identity.Operations.WithdrawInvite do
  @moduledoc """
  The admin's retirement of an outstanding invitation (#502): stamps
  `invite_withdrawn_at` (idempotent — a second call keeps the original
  stamp), so :accept_invite's WHERE filter matches nothing from that
  moment. An accepted account is not a withdraw target — the action's
  filter refuses with StaleRecord, and this seam lets that error
  propagate.
  """

  alias FluxVale.Identity.User

  @doc """
  Withdraws the invite of `user_or_id`. `opts` ride the read and the
  update (e.g. `authorize?: false` for operator tooling).
  """
  @spec call(User.t() | nil, User.t() | Ash.UUID.t(), keyword()) ::
          {:ok, User.t()} | {:error, term()}
  def call(actor, user_or_id, opts \\ []) do
    case user_or_id do
      %User{} = user ->
        withdraw(user, actor, opts)

      user_id when is_binary(user_id) ->
        case Ash.get(User, user_id, Keyword.put(opts, :actor, actor)) do
          {:ok, user} -> withdraw(user, actor, opts)
          {:error, error} -> {:error, error}
        end
    end
  end

  # The admin path rides actor through opts (the RevokePat posture):
  # policies run by default; operator tooling passes authorize?: false.
  defp withdraw(user, actor, opts) do
    User.withdraw_invite(user, Keyword.put(opts, :actor, actor))
  end
end
