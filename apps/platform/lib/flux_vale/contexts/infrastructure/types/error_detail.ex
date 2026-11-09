defmodule FluxVale.Infrastructure.Types.ErrorDetail do
  @moduledoc """
  The Instance and AccessGateway error-handler actions' `:error`
  argument's storage shape (#645, ADR-0048). The audit trail stores
  action inputs verbatim, and a caught exception struct cannot
  JSON-encode into `version_action_inputs`. The dump normalizes any
  exception to `%{"kind" => module, "message" => bounded_text}` —
  the module name plus a one-line, 200-char-bounded message — because
  raw error text can embed request bodies, secret names, connection
  details, or unbounded output. Cast passes the struct through
  untouched, so the handler's runtime semantics are unchanged (the
  mark_* changes never read the argument; it is pure audit payload).
  """

  use Ash.Type.NewType, subtype_of: :map

  # One line, 200 chars: enough to name the failure, never a dump of
  # whatever the underlying client put in the message.
  @message_bound 200

  @impl Ash.Type
  def dump_to_embedded(value, constraints) when is_exception(value) do
    message =
      value
      |> Exception.message()
      |> String.replace("\n", " ")
      |> String.slice(0, @message_bound)

    dump_to_embedded(%{"kind" => inspect(value.__struct__), "message" => message}, constraints)
  end

  def dump_to_embedded(value, constraints) do
    super(value, constraints)
  end
end
