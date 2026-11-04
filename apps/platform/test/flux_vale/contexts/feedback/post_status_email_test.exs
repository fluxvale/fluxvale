defmodule FluxVale.Feedback.PostStatusEmailTest do
  @moduledoc false

  # The author-notification slice (fluxvale/fluxvale#412 T7): a fresh
  # status move mails the post's author, a re-assertion mails nothing,
  # an unresolvable author skips quietly, and a mail failure never fails
  # the action (the TopupOutcomeMail discipline). Copy-level assertions
  # (all six status phrases, the punctuation rule) live in mailer_test
  # (the deliver_* split).

  use FluxVale.DataCase, async: true
  use Mimic

  setup :verify_on_exit!

  alias FluxVale.Feedback.Post
  alias FluxVale.Identity.User
  alias FluxVale.Mailer
  alias FluxVale.TestSupport.AccountsFixtures

  # Precondition posture (mirrors the seeds): the fixture runs
  # `authorize?: false` with the author riding as the actor, so
  # created_by_user_id is stamped by the create contract itself.
  defp authored_post!(author) do
    Post.create!(
      %{title: "Author mail post #{System.unique_integer([:positive])}", description: "x"},
      actor: author,
      authorize?: false
    )
  end

  defp admin, do: AccountsFixtures.platform_admin!()

  test "a fresh status move mails the author with the status phrase and title" do
    author = AccountsFixtures.user!()
    post = authored_post!(author)

    assert {:ok, moved} = Post.set_status(post, %{status: :started}, actor: admin())

    assert_receive {:email, %Swoosh.Email{to: [{_, to}], subject: subject, text_body: body}}

    assert to == to_string(author.email)
    assert subject == "Your FluxVale feedback post is now started"
    assert body =~ moved.title
    assert body =~ "https://fluxvale.com/feedback/#{moved.slug}"
  end

  test "re-asserting the same status mails nothing" do
    author = AccountsFixtures.user!()
    post = authored_post!(author)

    assert {:ok, moved} = Post.set_status(post, %{status: :planned}, actor: admin())
    assert_receive {:email, _}

    # The caller's current record rides back from the first move — the
    # before/after comparison (changeset.data vs result) is the caller's
    # old/new pair, so the re-assertion stamps nothing and mails nothing.
    assert {:ok, _reasserted} = Post.set_status(moved, %{status: :planned}, actor: admin())
    refute_received {:email, _}
  end

  test "a refused set_status mails nothing (the error passes through untouched)" do
    author = AccountsFixtures.user!()
    post = authored_post!(author)

    assert {:error, %Ash.Error.Invalid{}} =
             Post.set_status(post, %{status: :duplicate}, actor: admin())

    refute_received {:email, _}
  end

  test "an authorless system row skips quietly with the info log" do
    owner = AccountsFixtures.user!()
    org = AccountsFixtures.owned_org!(owner)

    # The system-caller posture (bootstrap, mirrors the seeds): no actor,
    # authorize?: false, a named org — SetActorDefaults stamps a nil
    # author.
    assert {:ok, post} =
             Post.create(
               %{title: "System row post", description: "x", organization_id: org.id},
               authorize?: false
             )

    assert is_nil(post.created_by_user_id)

    # The suite runs at :warning (config/test.exs), so the info line
    # needs the level opened for this test and restored after (the
    # mint_pat_test posture).
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)

    {_result, log} =
      ExUnit.CaptureLog.with_log(fn ->
        assert {:ok, _moved} = Post.set_status(post, %{status: :completed}, actor: admin())
      end)

    refute_received {:email, _}
    assert log =~ "has no mailable author address"
  end

  test "an author without a resolvable primary email skips quietly" do
    # Ash.seed! — the only way to produce a table-backed account without
    # its verified primary row (the create mirror always writes one and
    # RemoveGuard refuses to remove an account's only verified address:
    # unproducible through actions, the documented seed! exception).
    author =
      Ash.Seed.seed!(User, %{
        email: "mirrorless-#{System.unique_integer([:positive])}@fluxvale.test"
      })

    # The named org rides regardless of the actor, so the create succeeds
    # and stamps the mirror-less author.
    owner = AccountsFixtures.user!()
    org = AccountsFixtures.owned_org!(owner)

    assert {:ok, post} =
             Post.create(
               %{title: "No address post", description: "x", organization_id: org.id},
               actor: author,
               authorize?: false
             )

    assert post.created_by_user_id == author.id

    assert {:ok, _moved} = Post.set_status(post, %{status: :declined}, actor: admin())
    refute_received {:email, _}
  end

  test "a delivery failure logs the error and never fails the action" do
    author = AccountsFixtures.user!()
    post = authored_post!(author)

    stub(Mailer, :deliver_feedback_status_changed, fn _to, _status, _title, _slug ->
      {:error, :postmark_down}
    end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, moved} = Post.set_status(post, %{status: :started}, actor: admin())
        assert moved.status == :started
      end)

    refute_received {:email, _}
    assert log =~ "author mail failed"
    assert log =~ ":postmark_down"
  end
end
