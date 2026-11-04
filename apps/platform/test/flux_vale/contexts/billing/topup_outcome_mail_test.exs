defmodule FluxVale.Billing.TopupOutcomeMailTest do
  @moduledoc false

  # The email twin of the result state (#377): fresh transitions mail,
  # replays and pending never do, and a mail failure never fails the
  # caller. The controller/LiveView/worker hooks are covered in their
  # own suites; this pins the mail layer itself.

  use FluxVale.DataCase, async: true
  use Mimic

  setup :verify_on_exit!

  alias FluxVale.Billing
  alias FluxVale.Billing.Topup
  alias FluxVale.Billing.TopupOutcomeMail
  alias FluxVale.Mailer
  alias FluxVale.TestSupport.BillingFixtures

  # Completes through the real operation so the row, the credit, and
  # the result shape are exactly what the hooks see.
  defp completed_result!(payment_request_id, amount_cents) do
    {org, _wallet} = BillingFixtures.funded_wallet!(balance_cents: 0)

    {:ok, topup} =
      Topup.create(
        %{
          organization_id: org.id,
          amount_cents: amount_cents,
          buyer_email: "buyer@example.com"
        },
        authorize?: false
      )

    {:ok, _attached} =
      Topup.attach_checkout(topup, %{payment_request_id: payment_request_id}, authorize?: false)

    Billing.complete_topup(%{
      payment_request_id: payment_request_id,
      payment_id: payment_request_id,
      amount_cents: amount_cents,
      idempotency_key: "outcome-mail:" <> payment_request_id
    })
  end

  defp failed_topup! do
    {org, _wallet} = BillingFixtures.funded_wallet!(balance_cents: 0)

    {:ok, topup} =
      Topup.create(
        %{organization_id: org.id, amount_cents: 500, buyer_email: "buyer@example.com"},
        authorize?: false
      )

    {:ok, _attached} =
      Topup.attach_checkout(topup, %{payment_request_id: "pr_mail_fail"}, authorize?: false)

    Billing.fail_topup("pr_mail_fail")
  end

  describe "deliver_completed/1" do
    test "mails the amount, the credit, and the resulting balance" do
      {:ok, completed} = completed_result!("pr_mail_done", 500)

      assert :ok = TopupOutcomeMail.deliver_completed(completed)

      assert_receive {:email, %Swoosh.Email{text_body: body} = email}
      assert email.to == [{"", "buyer@example.com"}]
      assert body =~ "payment of $5.00"
      assert body =~ "balance is now $5.00"
    end

    test "a row without a buyer email skips the mail, not the :ok" do
      {org, _wallet} = BillingFixtures.funded_wallet!(balance_cents: 0)

      # The wizard always captures one; a hand-built row need not —
      # nothing to send is a skip, never a crash.
      {:ok, topup} =
        Topup.create(%{organization_id: org.id, amount_cents: 500}, authorize?: false)

      {:ok, _attached} =
        Topup.attach_checkout(topup, %{payment_request_id: "pr_mail_anon"}, authorize?: false)

      {:ok, completed} =
        Billing.complete_topup(%{
          payment_request_id: "pr_mail_anon",
          payment_id: "pr_mail_anon",
          amount_cents: 500,
          idempotency_key: "outcome-mail:anon"
        })

      assert :ok = TopupOutcomeMail.deliver_completed(completed)
      refute_received {:email, _email}
    end

    test "a mail failure logs and still answers :ok" do
      {:ok, completed} = completed_result!("pr_mail_down", 500)

      stub(Mailer, :deliver_topup_completed, fn _to, _amount, _balance ->
        {:error, :postmark_down}
      end)

      assert :ok = TopupOutcomeMail.deliver_completed(completed)
      refute_received {:email, _email}
    end
  end

  describe "deliver_not_completed/1" do
    test "mails the failed outcome with the retry link" do
      {:ok, failed} = failed_topup!()

      assert :ok = TopupOutcomeMail.deliver_not_completed(failed)

      assert_receive {:email, %Swoosh.Email{subject: subject, text_body: body}}
      assert subject == "Your FluxVale payment didn't go through"
      assert body =~ "You can try again at https://fluxvale.com/billing/topup."
    end

    test "mails the expired outcome" do
      {org, _wallet} = BillingFixtures.funded_wallet!(balance_cents: 0)

      {:ok, topup} =
        Topup.create(
          %{organization_id: org.id, amount_cents: 500, buyer_email: "buyer@example.com"},
          authorize?: false
        )

      {:ok, expired} = Topup.mark_expired(topup, %{}, authorize?: false)

      assert :ok = TopupOutcomeMail.deliver_not_completed(expired)

      assert_receive {:email, %Swoosh.Email{subject: "Your FluxVale top-up expired"}}
    end

    test "a pending row has no mailable outcome" do
      {org, _wallet} = BillingFixtures.funded_wallet!(balance_cents: 0)

      {:ok, pending} =
        Topup.create(
          %{organization_id: org.id, amount_cents: 500, buyer_email: "buyer@example.com"},
          authorize?: false
        )

      assert :ok = TopupOutcomeMail.deliver_not_completed(pending)
      refute_received {:email, _email}
    end

    test "a mail failure logs and still answers :ok" do
      {:ok, failed} = failed_topup!()

      stub(Mailer, :deliver_topup_not_completed, fn _to, _outcome -> {:error, :postmark_down} end)

      assert :ok = TopupOutcomeMail.deliver_not_completed(failed)
      refute_received {:email, _email}
    end
  end

  describe "the passthrough helpers" do
    test "on_completion mails the fresh transition and hands the result back" do
      result = completed_result!("pr_mail_pass", 500)

      assert {:ok, %Topup{}} = TopupOutcomeMail.on_completion(result)
      assert_receive {:email, %Swoosh.Email{subject: "Your FluxVale payment went through"}}
    end

    test "replays and errors pass through untouched and mail nothing" do
      assert {:ok, :already_completed} = TopupOutcomeMail.on_completion({:ok, :already_completed})
      assert {:ok, :already_terminal} = TopupOutcomeMail.on_failure({:ok, :already_terminal})
      assert {:error, :db_down} = TopupOutcomeMail.on_completion({:error, :db_down})
      refute_received {:email, _email}
    end

    test "on_failure mails the fresh failure and hands the result back" do
      result = failed_topup!()

      assert {:ok, %Topup{}} = TopupOutcomeMail.on_failure(result)
      assert_receive {:email, %Swoosh.Email{subject: "Your FluxVale payment didn't go through"}}
    end
  end
end
