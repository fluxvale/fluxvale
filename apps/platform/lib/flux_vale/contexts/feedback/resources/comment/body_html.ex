defmodule FluxVale.Feedback.Comment.BodyHtml do
  @moduledoc """
  The comment's rendered body (fluxvale/fluxvale#488): the untrusted
  Markdown body through `FluxVale.Feedback.Markdown`.

  Computed at READ time, not stored — a sanitizer change applies to
  rows already in the database on their next read — and loaded with the
  list, so island re-renders (every keystroke re-renders the form)
  interpolate a ready string instead of re-parsing every body through
  the Markdown pipeline.
  """

  use Ash.Resource.Calculation

  alias FluxVale.Feedback.Markdown

  @impl Ash.Resource.Calculation
  def calculate(records, _opts, _context) do
    Enum.map(records, fn record -> Markdown.render(record.body) end)
  end
end
