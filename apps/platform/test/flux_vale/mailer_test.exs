defmodule FluxVale.MailerTest do
  @moduledoc false

  # The recipient split at the mailer seam (ADR-0003 Am. 2): test-account
  # mail captures into TestInbox storage; everyone else rides the
  # configured adapter — in this env, Swoosh.Adapters.Test. The
  # disabled-config branch lives in test_inbox_gate_test (env mutation is
  # not async-safe).

  use ExUnit.Case, async: true

  alias FluxVale.Mailer
  alias FluxVale.TestInbox

  describe "deliver_auth_code/2 with the split" do
    test "a test account captures — never reaches the delivery adapter" do
      {:ok, _delivery} = Mailer.deliver_auth_code("test+split-a@fluxvale.com", "123456")

      assert {:ok, mail} = TestInbox.latest_mail("test+split-a@fluxvale.com")
      assert mail.code == "123456"

      # The configured adapter (Swoosh.Adapters.Test) saw nothing
      refute_received {:email, _email}
    end

    test "anyone else delivers through the configured adapter" do
      {:ok, _delivery} = Mailer.deliver_auth_code("split-human@fluxvale.com", "654321")

      assert_receive {:email, %Swoosh.Email{to: [{_, "split-human@fluxvale.com"}]}}

      # And the inbox never saw it
      assert {:error, :not_found} = TestInbox.latest_mail("split-human@fluxvale.com")
    end

    test "mixed recipients deliver — a human's copy is never swallowed by capture" do
      email =
        %Swoosh.Email{}
        |> Swoosh.Email.to([{"", "test+mixed@fluxvale.com"}, {"", "mixed-human@fluxvale.com"}])
        |> Swoosh.Email.from({"FluxVale", "no-reply@fluxvale.com"})
        |> Swoosh.Email.subject("Both of you")
        |> Swoosh.Email.text_body("One body")

      {:ok, _delivery} = Mailer.deliver(email)

      assert_receive {:email, %Swoosh.Email{subject: "Both of you"}}

      assert {:error, :not_found} = TestInbox.latest_mail("test+mixed@fluxvale.com")
    end

    # CodeRabbit #47: the recipient list is to + cc + bcc — a human in any
    # of them means the mail delivers
    test "a cc'd human blocks capture" do
      email =
        %Swoosh.Email{}
        |> Swoosh.Email.to("test+cc@fluxvale.com")
        |> Swoosh.Email.cc("cc-human@fluxvale.com")
        |> Swoosh.Email.from({"FluxVale", "no-reply@fluxvale.com"})
        |> Swoosh.Email.subject("CC'd human")
        |> Swoosh.Email.text_body("Body")

      {:ok, _delivery} = Mailer.deliver(email)

      assert_receive {:email, %Swoosh.Email{subject: "CC'd human"}}

      assert {:error, :not_found} = TestInbox.latest_mail("test+cc@fluxvale.com")
    end

    test "a bcc'd human blocks capture" do
      email =
        %Swoosh.Email{}
        |> Swoosh.Email.to("test+bcc@fluxvale.com")
        |> Swoosh.Email.bcc("bcc-human@fluxvale.com")
        |> Swoosh.Email.from({"FluxVale", "no-reply@fluxvale.com"})
        |> Swoosh.Email.subject("BCC'd human")
        |> Swoosh.Email.text_body("Body")

      {:ok, _delivery} = Mailer.deliver(email)

      assert_receive {:email, %Swoosh.Email{subject: "BCC'd human"}}

      assert {:error, :not_found} = TestInbox.latest_mail("test+bcc@fluxvale.com")
    end

    test "delivered mail still carries the plain-code body (ADR-0003)" do
      {:ok, _delivery} = Mailer.deliver_auth_code("split-body@fluxvale.com", "765432")

      assert_receive {:email, email}
      assert email.text_body =~ "765432"
    end
  end

  describe "deliver_low_balance_warning/2 (#124)" do
    test "carries the runway hours and the stop/restart promise" do
      {:ok, _delivery} = Mailer.deliver_low_balance_warning("low-runway@fluxvale.com", 7)

      assert_receive {:email,
                      %Swoosh.Email{subject: "Your FluxVale balance is running low"} = email}

      assert email.text_body =~ "about 7 hours"
      assert email.text_body =~ "start again once the balance is positive"
    end

    test "a spent balance swaps the copy instead of negative hours" do
      {:ok, _delivery} = Mailer.deliver_low_balance_warning("spent@fluxvale.com", -3)

      assert_receive {:email, %Swoosh.Email{text_body: body}}
      assert body =~ "has run out at current usage"
      refute body =~ "about -3 hours"
    end
  end

  describe "deliver_destroy_warning/3 (#124)" do
    test "T-7 names the date and the way out" do
      destroy_on = ~D[2026-11-12]

      {:ok, _delivery} = Mailer.deliver_destroy_warning("t7@fluxvale.com", destroy_on, 7)

      assert_receive {:email, %Swoosh.Email{subject: subject, text_body: body}}
      assert subject == "Your FluxVale instances will be deleted in 7 days"
      assert body =~ "On November 12, 2026"
      assert body =~ "deleted for good"
    end

    test "T-1 reads as one day" do
      {:ok, _delivery} = Mailer.deliver_destroy_warning("t1@fluxvale.com", ~D[2026-11-12], 1)

      assert_receive {:email, %Swoosh.Email{subject: subject}}
      assert subject == "Your FluxVale instances will be deleted in 1 day"
    end
  end
end
