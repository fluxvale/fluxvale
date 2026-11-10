defmodule FluxVale.Checks.CallOutsideMachineApi do
  @moduledoc """
  Policy check: this call originates outside the machine API (#644).

  Not actor-shaped, deliberately: the repo's check grammar reads
  `Actor<Assertion>` for actor questions, and this is a call question —
  the same person is a platform-admin actor on the web console and a
  scoped credential at the machine API. The blanket-admin bypass
  conditions on this check so the doctrine never rides a PAT (the
  authority plan's D2) while every existing pure-actor arm keeps
  today's semantics byte-for-byte.

  Two rungs, both set by the one PAT boundary left standing — and the
  process rung rides wherever the context rung cannot, so the refusal
  survives nested action calls (a generic action's inner `get_by_id`
  drops the request context; it cannot drop the process):

  - `/api/v1` — the plug chain bridges the calling PAT's scopes into
    the Ash request context
    (`FluxVale.Api.Scopes.pat_scopes_context_key/0`, written by
    `PutPatScopesInAshContext` for every PAT call and absent for
    session calls); a policy check reads that context through its
    subject (`context.subject.context` — the same seam Ash's own
    `ContextEquals` check uses). The same plug ALSO marks the request
    process (`mark_process!/0`): the context rung holds for
    context-propagating calls, the process rung for everything nested
    beneath them.

  The retired `/mcp` boundary (the Phantom endpoint, retired at the
  ADR-0019 Am. 5 cutover) was the second writer: its handlers marked
  the process directly. Its writer died with the endpoint; the check
  and the doctrine stay whole on `/api/v1` alone. The only leak
  surface is a test process that drove the boundary directly, and
  its direction is conservative: the refusal extends to later direct
  calls in that same process, never the reverse.

  Session callers and actorless system paths (Oban, webhooks, seeds)
  carry no marker of either kind — outside the machine API by the
  doctrine's definition, so the bypass may admit them on the actor
  check alone.
  """

  use Ash.Policy.SimpleCheck

  alias FluxVale.Api.Scopes

  # The process-dictionary mark both PAT boundaries set through
  # `mark_process!/0`. ONE owner each side, the `pat_scopes_context_key`
  # posture: the boundaries write it, this check reads it — a bare atom
  # duplicated across modules would degrade quietly to "unmarked",
  # indistinguishable from a session call.
  @machine_api_mark :flux_vale_machine_api_call

  @impl Ash.Policy.Check
  def describe(_opts), do: "call originates outside the machine API"

  @doc """
  The process mark's dictionary key — exported for the boundary writers
  and the tests that stage and clean the mark.
  """
  @spec machine_api_mark_key() :: atom()
  def machine_api_mark_key, do: @machine_api_mark

  @doc """
  Marks the calling process as a machine-API request process — the one
  writer-side helper the PAT boundary calls (the `/api/v1` chain's
  `PutPatScopesInAshContext`), so the refusal survives NESTED action
  calls: the mark rides the request process, and actions — outer and
  inner alike — run in it.
  """
  @spec mark_process!() :: :ok
  def mark_process! do
    Process.put(@machine_api_mark, true)
    :ok
  end

  @impl Ash.Policy.SimpleCheck
  def match?(_actor, context, _opts) do
    not machine_api?(context)
  end

  # Rung 1: the request-context marker (the /api/v1 bridge). A nil
  # subject context — every non-plug caller, sessions included — has
  # no marker and no key to find.
  defp machine_api?(%{subject: %{context: subject_context}})
       when is_map(subject_context) do
    Map.has_key?(subject_context, Scopes.pat_scopes_context_key()) or process_marked?()
  end

  defp machine_api?(_subject_without_context), do: process_marked?()

  # Rung 2: the process mark (the MCP boundary). A bare `true` — the
  # mark answers WHERE the call rides, nothing else.
  defp process_marked? do
    Process.get(@machine_api_mark) == true
  end
end
