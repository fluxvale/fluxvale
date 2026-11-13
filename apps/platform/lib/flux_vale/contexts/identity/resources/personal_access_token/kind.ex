defmodule FluxVale.Identity.PersonalAccessToken.Kind do
  @moduledoc """
  Which credential a `personal_access_tokens` row is (#766): the
  original long-lived PAT, or one half of an OAuth token pair.

  The prefix and the kind agree at the bearer plug: `fvpat_` resolves
  only `:pat`, `fvoat_` only `:oauth_access`; `fvort_` refresh tokens
  never authenticate an API call.
  """

  use Ash.Type.Enum, values: [:pat, :oauth_access, :oauth_refresh]
end
