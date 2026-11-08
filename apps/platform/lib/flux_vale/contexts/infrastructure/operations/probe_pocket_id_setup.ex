defmodule FluxVale.Infrastructure.Operations.ProbePocketIdSetup do
  @moduledoc """
  The mid-setup probe (#597 §4.1): asks a Pocket ID instance's own
  public endpoint whether its first-boot admin account is still
  unclaimed — `GET <public URL>/api/signup/setup`.

  The wire contract (§2's live transcript, image v2.19.2): **204** =
  setup still available (admin unclaimed — the instance can't mint
  OIDC clients yet); **404** = setup completed (the offer's green
  light). Anything else — another status, a timeout, a refused
  connection — is `:unreachable`: the honest answer, not an error.
  Failures shape the wizard's offer copy; they never break the wizard
  (D3's posture applied one step earlier).

  The only Pocket ID API call S3 makes: read-only, unauthenticated
  (the endpoint is public), short (~3s) — the wizard renders step 2
  while it runs and caches the answer for its life.
  """

  @setup_path "/api/signup/setup"

  # ~3s (§4.1): long enough for a cold Traefik route, short enough
  # that a dead host can't stall the wizard's step-2 render.
  @receive_timeout 3_000

  @typedoc """
  The probe's answer: `:completed` (404 — admin claimed), `:mid_setup`
  (204 — admin unclaimed), `:unreachable` (anything else).
  """
  @type status :: :completed | :mid_setup | :unreachable

  @doc """
  Probes the instance's public setup endpoint. Never returns `{:error, _}`:
  an unreachable or oddly-answering Pocket ID is `:unreachable`, an
  answer the caller renders, not one it rescues.
  """
  @spec call(FluxVale.Infrastructure.Instance.t()) :: status()
  def call(%FluxVale.Infrastructure.Instance{} = instance) do
    base_domain = Application.fetch_env!(:flux_vale, :instances_base_domain)
    url = "https://#{instance.slug}.#{base_domain}#{@setup_path}"

    # No redirects needed (the platform's own edge serves the route);
    # they'd only mask a misconfigured hostname as success.
    case Req.get(url, receive_timeout: @receive_timeout, redirect: false) do
      {:ok, %Req.Response{status: 204}} -> :mid_setup
      {:ok, %Req.Response{status: 404}} -> :completed
      _answered_or_failed -> :unreachable
    end
  end
end
