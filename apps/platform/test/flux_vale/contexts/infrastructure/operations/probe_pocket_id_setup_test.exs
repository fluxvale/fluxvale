defmodule FluxVale.Infrastructure.Operations.ProbePocketIdSetupTest do
  @moduledoc false

  # The probe's wire contract (#597 §4.1, pinned against §2's live
  # transcript): one GET against the Pocket ID instance's public setup
  # endpoint with a ~3s budget — 204 = admin unclaimed (:mid_setup),
  # 404 = done (:completed), anything else or a transport failure =
  # :unreachable. Never an error: the answer degrades the offer copy,
  # it never breaks the wizard. HTTP is Mimic-stubbed (the Tailscale
  # ApiClient stance): the probe translates wires into answers, it
  # does not talk to a live Pocket ID.

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Infrastructure
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.ProbePocketIdSetup

  # The probe reads only the slug (URL derivation) and app config — a
  # bare struct is the honest precondition for a pure wire-translation
  # test, no DB row needed.
  defp instance do
    %Instance{slug: "quiet-otter-42"}
  end

  defp setup_url do
    base_domain = Application.fetch_env!(:flux_vale, :instances_base_domain)
    "https://quiet-otter-42.#{base_domain}/api/signup/setup"
  end

  # The one-request contract every test shares: the public setup path
  # on the instance's derived URL, the short budget, no redirects.
  defp expect_setup(respond) do
    url = setup_url()

    expect(Req, :get, fn request_url, opts ->
      assert request_url == url
      assert opts[:receive_timeout] == 3_000
      assert opts[:redirect] == false
      respond.()
    end)
  end

  test "204 = first-boot not completed — :mid_setup" do
    expect_setup(fn -> {:ok, %Req.Response{status: 204}} end)

    assert ProbePocketIdSetup.call(instance()) == :mid_setup
  end

  test "404 = setup completed — :completed" do
    expect_setup(fn -> {:ok, %Req.Response{status: 404}} end)

    assert ProbePocketIdSetup.call(instance()) == :completed
  end

  # Any other answer is not an answer: a 500, a redirect-shaped 302,
  # a timeout — all degrade to the same honest "can't check".
  test "any other status is :unreachable" do
    expect_setup(fn -> {:ok, %Req.Response{status: 503}} end)
    assert ProbePocketIdSetup.call(instance()) == :unreachable

    expect_setup(fn -> {:ok, %Req.Response{status: 302}} end)
    assert ProbePocketIdSetup.call(instance()) == :unreachable
  end

  test "a transport failure (timeout, refused) is :unreachable, never a raise" do
    expect_setup(fn -> {:error, %Req.TransportError{reason: :timeout}} end)
    assert ProbePocketIdSetup.call(instance()) == :unreachable
  end

  # The domain seam: the same call rides the domain's public surface.
  test "rides the Infrastructure domain seam" do
    expect_setup(fn -> {:ok, %Req.Response{status: 404}} end)

    assert Infrastructure.probe_pocketid_setup(instance()) == :completed
  end
end
