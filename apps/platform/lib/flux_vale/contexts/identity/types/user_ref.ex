defmodule FluxVale.Identity.Types.UserRef do
  @moduledoc """
  The UserEmail `:user` manage_relationship argument's storage shape
  (#645, ADR-0048). The audit trail stores action inputs verbatim, and
  a caller-passed `%User{}` struct — the code interface's idiomatic
  input — cannot JSON-encode into `version_action_inputs`. The dump
  normalizes the struct to the `%{"id" => id}` map the audit view
  needs; cast passes the struct through untouched, so the
  manage_relationship keeps its no-lookup append semantics.
  """

  use Ash.Type.NewType, subtype_of: :map

  @impl Ash.Type
  def dump_to_embedded(%FluxVale.Identity.User{} = user, constraints) do
    dump_to_embedded(%{"id" => user.id}, constraints)
  end

  def dump_to_embedded(value, constraints) do
    super(value, constraints)
  end
end
