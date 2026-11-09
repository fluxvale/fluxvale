defmodule FluxValeWeb.AuthFlowTest do
  @moduledoc """
  The Google arm's copy contract (#642): one home per string — the
  shared reasons reuse the email arm's copy verbatim, the Google-only
  atoms name the email-code alternative (plan §5). Pinned here where
  the strings are the point; the controller matrix drives the same
  mapping end-to-end.
  """

  use ExUnit.Case, async: true

  alias FluxValeWeb.AuthFlow

  test "google_outcome/1 passes the mint through" do
    assert AuthFlow.google_outcome({:ok, %{id: 1}, "token"}) == {:ok, %{id: 1}, "token"}
  end

  test "the shared atoms reuse the email arm's copy verbatim" do
    assert {:error, copy} = AuthFlow.google_outcome({:error, :not_allowed})
    assert copy == "That address can't sign in yet. Ask an admin for access."

    assert {:error, wall} = AuthFlow.google_outcome({:error, :invitation_required})
    assert {:error, invite} = AuthFlow.google_outcome({:error, :invite_pending})

    assert wall == elem(AuthFlow.verify_outcome({:error, :invitation_required}), 1)
    assert invite == elem(AuthFlow.verify_outcome({:error, :invite_pending}), 1)
  end

  test "an unverified claim is told to fix it at Google — email door named" do
    assert {:error, copy} = AuthFlow.google_outcome({:error, :email_not_verified})
    assert copy =~ "isn't verified by Google"
    assert copy =~ "email code"
  end

  # The VerifyAuthCode residuals (plan §3.3): the post-supersede race
  # window and DB-read arms — a retryable refusal the controller
  # cannot stage sequentially (the operation's own suite covers the
  # atoms); the copy must never leak which one fired.
  test "every residual atom answers the same retry copy" do
    for atom <- [:address_unresolved, :user_lookup_failed, :provisioning_failed] do
      assert {:error, "Google sign-in didn't work. Please try again, or use an email code."} =
               AuthFlow.google_outcome({:error, atom})
    end
  end

  test "the door-shut and throttle copy" do
    assert AuthFlow.google_unavailable() ==
             "Google sign-in isn't available here. Use an email code."

    assert AuthFlow.google_throttled() == "Please wait a minute before trying again."
  end
end
