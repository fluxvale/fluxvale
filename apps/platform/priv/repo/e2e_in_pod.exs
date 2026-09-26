# E2E in-pod runner (#75): seeds + the TestInbox PAT, exec'd by
# scripts/e2e-bootstrap.sh into the LIVE platform container — where the
# server process already owns :4000, so the app must come up with the
# endpoint listener off. The pod sets PHX_SERVER=true (runtime.exs sets
# `server: true` from it); `mix run --no-start` lands here and flips
# that key (and drops the dev watchers — nobody watches assets in an
# exec, and their async logs would drown the output contract). put_env
# on the whole config would clobber the endpoint's http/url/pubsub
# settings.
#
# seeds.exs / local_seeds.exs stay host-side `mix run` scripts; this
# wrapper evals them rather than forking their logic.
#
# Contract: the bare PAT sits between E2E_PAT_BEGIN / E2E_PAT_END
# sentinels — immune to any async log line.

endpoint_config = Application.get_env(:flux_vale, FluxValeWeb.Endpoint, [])

endpoint_config =
  endpoint_config
  |> Keyword.put(:server, false)
  |> Keyword.put(:watchers, [])

Application.put_env(:flux_vale, FluxValeWeb.Endpoint, endpoint_config)
{:ok, _} = Application.ensure_all_started(:flux_vale)

for script <- ["priv/repo/seeds.exs", "priv/repo/local_seeds.exs"] do
  Code.eval_file(script)
end

case FluxVale.Identity.User.mint_pat("admin@fluxvale.com", authorize?: false) do
  {:ok, token} ->
    IO.puts("E2E_PAT_BEGIN")
    IO.puts(token)
    IO.puts("E2E_PAT_END")

  {:error, error} ->
    IO.puts(:stderr, "PAT mint failed: #{Exception.message(error)}")
    System.halt(1)
end
