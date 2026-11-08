# Dev-only capture seed for the resource console shots (#595): a
# handful of feature flags and access rules so both index tables and
# the show page carry real, varied rows — enabled/disabled booleans, a
# rollout percentage against unset, both purposes, and a mixed-case
# email so the ci_string rendering shows its original case. Runs
# through the resource actions with the seeded admin as actor — the
# same policy path the console rides. Idempotent: existing flags are
# skipped and duplicate rules are refused by their own identity, so a
# re-run only tops up what a capture deleted.
#
# AccessRule's moduledoc says rows are never seeded — that rule is
# about environment bring-up (operator-entered, #26). This is the
# dev-only capture exception: rows for screenshots on a local DB.
#
# Run from apps/platform: mix run ../e2e/fv595_seed.exs

alias FluxVale.Identity.User
alias FluxVale.Ops.AccessRule
alias FluxVale.Ops.FeatureFlag

flags = [
  %{
    key: "feedback_board",
    enabled: true,
    rollout_percentage: 100,
    description: "The public feedback board, on for everyone"
  },
  %{
    key: "edge_wake_queue",
    enabled: false,
    rollout_percentage: 25,
    description: "Queue asleep-instance wakes through the edge"
  },
  %{
    key: "org_invites",
    enabled: true,
    description: "Invitation-based org growth"
  }
]

rules = [
  %{email: "Terence@FluxVale.com", purpose: :auth},
  %{domain: "fluxvale.com", purpose: :auth},
  %{email: "friend@example.org", purpose: :feedback}
]

{:ok, admin} = User.get_by_email("admin@fluxvale.com", authorize?: false)

for attrs <- flags do
  case FeatureFlag.by_key(attrs.key, actor: admin) do
    {:ok, _existing} ->
      :skip

    {:error, _not_found} ->
      FeatureFlag
      |> Ash.Changeset.for_create(:create, attrs, actor: admin)
      |> Ash.create!()

      IO.puts("flag #{attrs.key} created")
  end
end

for attrs <- rules do
  result =
    AccessRule
    |> Ash.Changeset.for_create(:create, attrs, actor: admin)
    |> Ash.create()

  case result do
    {:ok, _rule} ->
      IO.puts("rule #{inspect(attrs)} created")

    # Only the per-(purpose, shape) identity refusing a re-run's
    # duplicate reads as "skipped" — anything else (a policy refusal,
    # a bad value) fails the seed loudly instead of masquerading.
    {:error, %Ash.Error.Invalid{} = error} ->
      if Enum.any?(error.errors, &match?(%Ash.Error.Changes.InvalidAttribute{}, &1)) do
        IO.puts("rule #{inspect(attrs)} already present, skipped")
      else
        raise error
      end

    {:error, error} ->
      raise error
  end
end

IO.puts("seed done")
