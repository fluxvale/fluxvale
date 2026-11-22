defmodule FluxVale.Onboarding do
  @moduledoc """
  Onboarding completion, derived from real signals (#887).

  `onboarded_at` (#831) is the single persisted truth, and until #887
  it had exactly one writer: the user's own Skip/Finish click. The
  agent-first run proved the gap — an account whose agent authenticated
  via MCP and provisioned the first instance has done everything
  onboarding exists to achieve, yet every `/` visit bounced it back to
  step one. This module is the server-side completion predicate the
  issue asks for, plus the convergence that keeps the stamp the ONE
  truth: every surface reads `onboarded_at`, so the stamp heals here
  (best-effort) instead of growing a second live source of truth.

  The signals, both row-existence reads (status-independent on
  purpose — the MCP ladder counts instances the same way):

  - **Machine auth exists** — a live `personal_access_tokens` row for
    the user: `revoked_at` nil and `expires_at` in the future, any
    kind (the one table holds PATs and OAuth access/refresh pairs —
    every credential class an agent can hold).
  - **A first instance is provisioned** — an Instance row in an org
    the user belongs to, `:list_for_actor`'s exact scope (the
    dashboard's own `instance_count`), so the predicate and the
    dashboard can never disagree about what counts.
  """

  alias FluxVale.Identity.PersonalAccessToken
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.Instance

  require Ash.Query

  @doc """
  The predicate (#887): machine auth exists AND a first instance is
  provisioned. Pure, no writes. System reads (`authorize?: false`) —
  an internal invariant derivation over the caller's own account, the
  `count_live_derived!/1` posture.
  """
  @spec complete?(User.t()) :: boolean()
  def complete?(%User{} = user) do
    machine_auth?(user) and instance_provisioned?(user)
  end

  @doc """
  Resolve an account's onboarding, converging the stamp when the
  signals say done.

  Returns `{true, user}` when onboarding is complete for this account —
  the stamp was already set, or the signals say done and the
  `:finish_onboarding` write went through (set-once, so a manual
  finish later keeps the original stamp). Returns `{true, user}`
  unchanged when the signals say done but the stamp write refused —
  **best-effort by contract**: callers key their routing on the
  derived answer, never the write, so a DB hiccup degrades to a
  retried converge on the next visit, never a redirect loop (the
  gate's never-redirect-when-done rule). Returns `{false, user}` when
  the flow still has something to offer.
  """
  @spec converge(User.t()) :: {boolean(), User.t()}
  def converge(%User{onboarded_at: %DateTime{}} = user), do: {true, user}

  def converge(%User{} = user) do
    if complete?(user) do
      user
      |> Ash.Changeset.for_update(:finish_onboarding, %{})
      |> Ash.update(actor: user)
      |> converge_result(user)
    else
      {false, user}
    end
  end

  defp converge_result({:ok, stamped}, _original), do: {true, stamped}

  # coveralls-ignore-start — untestable by construction: the actor IS
  # the record owner (the policy admits it) and the action takes no
  # input, so the only refusals are infrastructure (DB down, the
  # documented unreasonable class). Returning the original keeps the
  # derived answer — the callers' no-loop rule keys on it, never on
  # the write, and the next visit retries the converge.
  defp converge_result({:error, _refused}, original), do: {true, original}
  # coveralls-ignore-stop

  # A live credential row of ANY kind: the table's every class is a
  # machine credential (PAT, OAuth access, OAuth refresh), so no kind
  # filter — one less thing to drift when a class is added.
  defp machine_auth?(%User{} = user) do
    now = DateTime.utc_now()

    PersonalAccessToken
    |> Ash.Query.filter(user_id == ^user.id and is_nil(revoked_at) and expires_at > ^now)
    |> Ash.exists?(authorize?: false)
  end

  # The dashboard's own scope, verbatim — `instance_count`'s read, so
  # "provisioned" means exactly what the dashboard shows a count of.
  defp instance_provisioned?(%User{} = user) do
    Instance
    |> Ash.Query.for_read(:list_for_actor, %{}, actor: user)
    |> Ash.exists?(authorize?: false)
  end
end
