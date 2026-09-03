defmodule FluxVale.Identity.Secrets do
  @moduledoc false

  use AshAuthentication.Secret

  @spec secret_for(list(), module(), keyword(), map()) :: {:ok, term()} | :error
  def secret_for(
        [:authentication, :tokens, :signing_secret],
        FluxVale.Identity.User,
        _opts,
        _context
      ) do
    Application.fetch_env(:flux_vale, :token_signing_secret)
  end
end
