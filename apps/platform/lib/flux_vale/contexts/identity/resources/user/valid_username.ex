defmodule FluxVale.Identity.User.ValidUsername do
  @moduledoc """
  The `:set_username` action's format gate (#285 T5) — a thin Ash
  validation over DeriveUsername's rule set (`format_problem/2`), so the
  rename and the signup derivation cannot drift apart: one regex, one
  reserved list. Uniqueness stays the `unique_username` identity's job.

  The reserved-list arm is admin-claimable (#870, the ReservedSlug #754
  precedent — brand words fence brand-surface claims, not the operator
  claiming the platform's own handle); everything else binds everyone.
  There is no machine-API route for `:set_username`, so the exemption is
  console-side only. The actorless arm reads as not-admin — reserved
  stays reserved.

  Timing contract: function validations run eagerly at for_update, so
  the actor must ride the BUILD call (`for_update(..., actor: ...)` —
  the settings/onboarding forms' shape). An actor attached only at
  Ash.update is invisible here, and a reserved refusal is the answer.
  """

  use Ash.Resource.Validation

  alias Ash.Resource.Validation
  alias FluxVale.Checks.ActorIsPlatformAdmin
  alias FluxVale.Identity.User.DeriveUsername

  @impl Validation
  def init(opts), do: {:ok, opts}

  @impl Validation
  def validate(changeset, _opts, context) do
    username = Ash.Changeset.get_argument_or_attribute(changeset, :username)

    # The check's own predicate — checks and plug-land share one module,
    # the role read is never re-implemented here.
    reserved_ok = ActorIsPlatformAdmin.platform_admin?(context.actor)

    case DeriveUsername.format_problem(username, reserved_ok) do
      nil -> :ok
      problem -> {:error, field: :username, message: problem}
    end
  end
end
