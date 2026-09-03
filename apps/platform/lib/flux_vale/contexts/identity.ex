defmodule FluxVale.Identity do
  @moduledoc """
  Identity: users, platform roles, and the revocable token store.

  Passwordless email-code sign-in (#21) and PATs (#23) build on this domain.
  Deliberately **not** exposed through AshAdmin — User/Token are sensitive
  resources (ADR-0027 §3).
  """

  use Ash.Domain, otp_app: :flux_vale

  resources do
    resource FluxVale.Identity.Token
    resource FluxVale.Identity.User
  end
end
