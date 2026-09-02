defmodule FluxVale.Identity.Secrets do
  @moduledoc false

  use AshAuthentication.Secret

  def secret_for(
        [:authentication, :tokens, :signing_secret],
        FluxVale.Identity.User,
        _opts,
        _context
      ) do
    Application.fetch_env(:flux_vale, :token_signing_secret)
  end
end
