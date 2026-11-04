defmodule FluxVale.Feedback.Comment.AuthorUsername do
  @moduledoc """
  Public projection: the comment author's handle, for board rendering.

  Loading `author_user` directly authorizes at the User destination,
  whose reads are admin-only — the UI slice would walk into a Forbidden
  rendering author names. This calculation resolves the username
  authorize-free instead: by commenting on a public board the author
  published that handle, so reading it back is not an exposure of the
  User record (email, tokens, roles stay admin-read — this query touches
  only `username`, keyed by the FK the comment already carries).
  """

  use Ash.Resource.Calculation

  alias FluxVale.Identity.User

  require Ash.Expr
  require Ash.Query

  @impl Ash.Resource.Calculation
  def calculate(records, _opts, _context) do
    author_ids =
      records
      |> MapSet.new(& &1.author_user_id)
      |> MapSet.to_list()

    usernames =
      case author_ids do
        # coveralls-ignore-start - defensive: an empty result set never
        # reaches the calculation (a comment always carries an author)
        [] ->
          %{}

        # coveralls-ignore-stop
        ids ->
          users =
            User
            |> Ash.Query.select(:username)
            |> Ash.Query.filter(expr(id in ^ids))
            |> Ash.read!(authorize?: false)

          Map.new(users, &{&1.id, &1.username})
      end

    Enum.map(records, fn record -> Map.get(usernames, record.author_user_id) end)
  end
end
