defmodule FluxVale.Infrastructure.Types.ErrorDetail do
  @moduledoc """
  The Instance error-handler actions' `:error` argument's storage shape
  (#645, ADR-0048). The audit trail stores action inputs verbatim, and
  a caught exception struct cannot JSON-encode into
  `version_action_inputs`. The dump normalizes any exception to the
  `%{"message" => message}` map the audit view needs; cast passes the
  struct through untouched, so the handler's runtime semantics are
  unchanged.
  """

  use Ash.Type.NewType, subtype_of: :map

  @impl Ash.Type
  def dump_to_embedded(value, constraints) when is_exception(value) do
    dump_to_embedded(%{"message" => Exception.message(value)}, constraints)
  end

  def dump_to_embedded(value, constraints) do
    super(value, constraints)
  end
end
