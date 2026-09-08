defmodule FluxVale.TestInboxTest do
  @moduledoc false

  # The capture predicate and the serving reads over Local storage.
  # Memory storage is process-global and these tests are async: every
  # test delivers to its own plus-addressed mailbox and asserts only
  # through the address-filtered API.

  use ExUnit.Case, async: true

  alias FluxVale.Mailer
  alias FluxVale.TestInbox

  describe "capture?/1 (the recipient split, ADR-0003 Am. 2)" do
    test "test@fluxvale.com captures" do
      email = mail_to("test@fluxvale.com")

      assert TestInbox.capture?(email)
    end

    test "plus-addressed variants capture (E2E gets private mailboxes)" do
      email = mail_to("test+pr42@fluxvale.com")

      assert TestInbox.capture?(email)
    end

    test "case-insensitive per RFC 5321" do
      email = mail_to("TEST+Pr42@FluxVale.com")

      assert TestInbox.capture?(email)
    end

    test "non-test recipients do not capture" do
      email = mail_to("someone@example.com")

      refute TestInbox.capture?(email)
    end

    test "other fluxvale.com locals are not test accounts" do
      email = mail_to("admin@fluxvale.com")

      refute TestInbox.capture?(email)
    end

    test "near-miss locals do not capture" do
      email = mail_to("testy@fluxvale.com")

      refute TestInbox.capture?(email)
    end

    test "no recipients: not a capture (nothing to capture for)" do
      refute TestInbox.capture?(%Swoosh.Email{})
    end
  end

  describe "list_mails/latest_mail over Local storage" do
    test "latest returns the newest mail for the address, code extracted" do
      {:ok, _delivery} = Mailer.deliver_auth_code("test+module-a@fluxvale.com", "111111")
      {:ok, _delivery} = Mailer.deliver_auth_code("test+module-a@fluxvale.com", "222222")

      assert {:ok, mail} = TestInbox.latest_mail("test+module-a@fluxvale.com")

      assert mail.code == "222222"
      assert mail.to == ["test+module-a@fluxvale.com"]
      assert mail.subject == "Your FluxVale sign-in code"
      assert is_binary(mail.id)
      assert is_binary(mail.sent_at)
    end

    test "latest for an address that never captured" do
      assert {:error, :not_found} = TestInbox.latest_mail("test+never@fluxvale.com")
    end

    test "the address filter scopes the list" do
      {:ok, _delivery} = Mailer.deliver_auth_code("test+module-b@fluxvale.com", "333333")

      mails = TestInbox.list_mails("test+module-b@fluxvale.com")

      assert mails != []
      assert Enum.all?(mails, &(&1.to == ["test+module-b@fluxvale.com"]))
    end

    test "code extraction is best-effort — no 6-digit run, no code" do
      email =
        %Swoosh.Email{}
        |> Swoosh.Email.to("test+module-c@fluxvale.com")
        |> Swoosh.Email.from({"FluxVale", "no-reply@fluxvale.com"})
        |> Swoosh.Email.subject("No digits here")
        |> Swoosh.Email.text_body("10 minutes, 30 days, no code")

      {:ok, _delivery} = Mailer.deliver(email)

      assert {:ok, mail} = TestInbox.latest_mail("test+module-c@fluxvale.com")
      assert mail.code == nil
    end
  end

  defp mail_to(address) do
    %Swoosh.Email{}
    |> Swoosh.Email.to(address)
    |> Swoosh.Email.from({"FluxVale", "no-reply@fluxvale.com"})
  end
end
