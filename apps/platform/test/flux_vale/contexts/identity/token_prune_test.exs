defmodule FluxVale.Identity.TokenPruneTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  alias FluxVale.Identity
  alias FluxVale.Identity.Token
  alias FluxVale.Janitor.PruneExpiredTokens
  alias FluxVale.Repo

  describe "Identity.prune_expired_tokens/1" do
    test "deletes only expired tokens" do
      expired = seed_token(expires_at: hours_from_now(-1))
      unexpired = seed_token(expires_at: hours_from_now(1))

      assert {:ok, 1} = Identity.prune_expired_tokens(authorize?: false)

      refute token_exists?(expired.jti)
      assert token_exists?(unexpired.jti)
    end

    test "deletes multiple expired tokens in one call" do
      t1 = seed_token(expires_at: hours_from_now(-2))
      t2 = seed_token(expires_at: hours_from_now(-1))
      _t3 = seed_token(expires_at: hours_from_now(1))

      assert {:ok, 2} = Identity.prune_expired_tokens(authorize?: false)

      refute token_exists?(t1.jti)
      refute token_exists?(t2.jti)
    end

    test "returns zero when no tokens are expired" do
      _unexpired = seed_token(expires_at: hours_from_now(1))

      assert {:ok, 0} = Identity.prune_expired_tokens(authorize?: false)
    end

    test "the janitor worker performs the prune" do
      _expired = seed_token(expires_at: hours_from_now(-1))
      _live = seed_token(expires_at: hours_from_now(1))

      # The cron-triggered entry point, exercised directly — the business
      # logic is Identity.prune_expired_tokens/1 (covered above)
      assert {:ok, 1} = PruneExpiredTokens.perform(%Oban.Job{})
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
      expires_at: hours_from_now(1)
    }

    Ash.Seed.seed!(Token, Map.merge(defaults, Map.new(attrs)))
  end

  defp hours_from_now(hours) do
    DateTime.add(DateTime.utc_now(), hours * 3600, :second)
  end
end
