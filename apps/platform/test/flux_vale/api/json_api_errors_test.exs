defmodule FluxVale.Api.JsonApiErrorsTest do
  @moduledoc false

  # #731 T2: MultipleResults is the honest multi-match refusal from
  # `get?` reads; the wire answer must name it instead of falling back
  # to ash_json_api's generic 400.

  use ExUnit.Case, async: true

  alias Ash.Error.Invalid.MultipleResults
  alias AshJsonApi.Error
  alias AshJsonApi.ToJsonApiError

  test "MultipleResults renders as a named 400" do
    error = MultipleResults.exception(count: 2, at_least?: true)

    assert %Error{
             id: id,
             status_code: 400,
             code: "multiple_results",
             title: "Multiple results",
             detail:
               "more than one record matches this query — narrow the filter; " <>
                 "for an instance slug lookup, pass organization_id or use the instance id"
           } = ToJsonApiError.to_json_api_error(error)

    assert is_binary(id)
  end
end
