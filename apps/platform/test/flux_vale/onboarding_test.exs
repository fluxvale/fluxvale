defmodule FluxVale.OnboardingTest do
  @moduledoc """
  The #887 completion predicate: both signals row-existence reads, the
  dead-credential classes (revoked, expired) excluded, every machine
  credential class admitted (PAT and OAuth rows alike), the instance
  arm scoped exactly like the dashboard's own count, and converge/1's
  three answers — done-as-was, done-by-signals (set-once on repeats),
  not-done with no write.
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.Identity
  alias FluxVale.Identity.User
  alias FluxVale.Onboarding
  alias FluxVale.TestSupport.InstanceFixtures
  alias FluxVale.TestSupport.OAuthFixtures
  alias FluxVale.TestSupport.SessionHelpers

  # The both-signals precondition: a live PAT row plus a first
  # instance in the user's own org — the agent-first-run shape.
  defp agent_run!(user) do
    pat!(user)
    instance!(user)
  end

  defp pat!(user) do
    {:ok, %{token: _raw}} =
      Identity.mint_pat(user, %{user_id: user.id, name: "onboarding-test", scopes: []})

    :ok
  end

  defp instance!(user) do
    InstanceFixtures.local_cluster!()
    version = InstanceFixtures.app_version!()
    InstanceFixtures.instance!(version, user)
  end

  defp reload(user), do: Ash.get!(User, user.id, authorize?: false)

  describe "complete?/1" do
    test "a bare account is not done — neither signal exists" do
      refute Onboarding.complete?(SessionHelpers.user!())
    end

    test "a live credential alone is not done — the first instance is the other arm" do
      user = SessionHelpers.user!()
      pat!(user)

      refute Onboarding.complete?(user)
    end

    test "a first instance alone is not done — machine auth is the other arm" do
      user = SessionHelpers.user!()
      instance!(user)

      refute Onboarding.complete?(user)
    end

    test "a live credential plus a first instance is done — the agent-first-run shape" do
      user = SessionHelpers.user!()
      agent_run!(user)

      assert Onboarding.complete?(user)
    end

    test "a revoked credential does not count — the agent connection is severed" do
      user = SessionHelpers.user!()

      {:ok, %{pat: pat}} =
        Identity.mint_pat(user, %{user_id: user.id, name: "onboarding-test", scopes: []})

      instance!(user)
      {:ok, _revoked} = Identity.revoke_pat(user, pat.id)

      refute Onboarding.complete?(user)
    end

    test "an expired credential does not count — liveness bounds the arm" do
      user = SessionHelpers.user!()

      {:ok, %{token: _raw}} =
        Identity.mint_pat(user, %{
          user_id: user.id,
          name: "onboarding-test",
          scopes: [],
          expires_at: DateTime.add(DateTime.utc_now(), -1, :hour)
        })

      instance!(user)

      refute Onboarding.complete?(user)
    end

    test "an OAuth connection counts — the exchange mints the machine credential" do
      user = SessionHelpers.user!()
      client = OAuthFixtures.client!()
      OAuthFixtures.tokens!(client, user)
      instance!(user)

      assert Onboarding.complete?(user)
    end

    test "another account's instance does not count — the arm is the dashboard's own scope" do
      user = SessionHelpers.user!()
      pat!(user)

      # The instance lands in someone else's personal org; `user` is
      # not a member there, so :list_for_actor's membership filter
      # excludes it — exactly what the dashboard counts.
      instance!(SessionHelpers.user!())

      refute Onboarding.complete?(user)
    end
  end

  describe "converge/1" do
    test "an already-stamped account answers done with no rewrite" do
      user = SessionHelpers.onboarded!(SessionHelpers.user!())

      {done, returned} = Onboarding.converge(user)

      assert done
      assert returned.onboarded_at == user.onboarded_at
    end

    test "a signal-complete account converges the stamp — the write-through" do
      user = SessionHelpers.user!()
      agent_run!(user)

      {done, returned} = Onboarding.converge(user)

      assert done
      assert reload(user).onboarded_at == returned.onboarded_at
    end

    test "a converged stamp keeps its original time — set-once, whichever writer lands" do
      user = SessionHelpers.user!()
      agent_run!(user)

      {_done, first} = Onboarding.converge(user)
      # A later manual finish (Skip/Finish in the flow) must not move it.
      second =
        user
        |> Ash.Changeset.for_update(:finish_onboarding, %{})
        |> Ash.update!(actor: user)

      assert second.onboarded_at == first.onboarded_at
      assert reload(user).onboarded_at == first.onboarded_at
    end

    test "an incomplete account answers not-done and writes nothing" do
      user = SessionHelpers.user!()
      pat!(user)

      {done, returned} = Onboarding.converge(user)

      refute done
      assert returned.onboarded_at == nil
      assert reload(user).onboarded_at == nil
    end
  end
end
