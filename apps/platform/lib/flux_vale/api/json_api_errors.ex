defmodule FluxVale.Api.JsonApiErrors do
  @moduledoc """
  Wire-shape impls for Ash errors ash_json_api 1.7.1 leaves unmapped.

  `Ash.Error.Invalid.MultipleResults` is `get?` reads' honest refusal —
  the instance-slug lookup when a slug matches more than one visible row
  (#731 T2). Without an impl the protocol falls back to a generic 400
  whose detail names only an error id, so the caller cannot tell what to
  narrow. The impl is resource-agnostic; the detail names the
  instance-slug remedy.
  """
end

# The EnvVarSpec encoder's shape (#362): the impl rides the file as a
# top-level sibling, because a protocol implementation is not a nested
# module.
defimpl AshJsonApi.ToJsonApiError, for: Ash.Error.Invalid.MultipleResults do
  @impl AshJsonApi.ToJsonApiError
  def to_json_api_error(_error) do
    %AshJsonApi.Error{
      id: Ash.UUID.generate(),
      status_code: 400,
      code: "multiple_results",
      title: "Multiple results",
      detail:
        "more than one record matches this query — narrow the filter; " <>
          "for an instance slug lookup, pass organization_id or use the instance id"
    }
  end
end
