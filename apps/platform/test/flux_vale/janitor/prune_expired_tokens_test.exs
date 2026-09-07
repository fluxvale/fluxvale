defmodule FluxVale.Janitor.PruneExpiredTokensTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  alias FluxVale.Identity.Token
  alias FluxVale.Janitor.PruneExpiredTokens
  alias FluxVale.Repo

  describe "perform/1" do
    test "prunes expired tokens through the Identity domain seam" do
      _expired = seed_token(expires_at: DateTime.add(DateTime.utc_now(), -3600, :second))
      live = seed_token(expires_at: DateTime.add(DateTime.utc_now(), 3600, :second))

      # The cron-triggered entry point, exercised directly — the business
      # logic is Identity.prune_expired_tokens/1 (own suite next door)
      assert {:ok, 1} = PruneExpiredTokens.perform(%Oban.Job{})
      assert token_exists?(live.jti)
    end
  end

  defp token_exists?(jti) do
    query = from(t in "tokens", where: t.jti == ^jti)
    Repo.exists?(query)
  end

  defp seed_token(attrs) do
    defaults = %{
      jti: "jti-#{System.unique_integer([:positive])}",
      subject: "user-test",
      purpose: "user",
      expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
    }

    Ash.Seed.seed!(Token, Map.merge(defaults, Map.new(attrs)))
  end
end
