defmodule FluxVale.Catalog.Types.CopyRules do
  @moduledoc """
  The curated-copy rules shared by the catalog's marketing types (#611):
  prose fields are length-bounded and reject em dashes (U+2014) and
  semicolons (D10) — short plain sentences keep the public pages
  scannable and translation-safe.

  `KnownFields.reject/2`'s stance: a small shared guard the map-shaped
  types apply, so seeds, admin, and the API enforce one set of copy
  rules at write time.
  """

  @em_dash "\u2014"
  @forbidden [{@em_dash, "an em dash"}, {";", "a semicolon"}]

  @doc """
  `:ok` when `text` obeys the copy rules (no em dashes, no semicolons),
  else an error naming the field and the fix.
  """
  @spec check(field :: atom() | String.t(), text :: String.t()) :: :ok | {:error, String.t()}
  def check(field, text) when is_binary(text) do
    case Enum.find(@forbidden, fn {char, _name} -> String.contains?(text, char) end) do
      nil ->
        :ok

      {_char, name} ->
        {:error, "#{field} must not contain #{name}. Use short plain sentences."}
    end
  end

  @doc """
  Length bounds first, then the copy rules — the arms read in the order
  authors hit them. `{:ok, text}` passes the text through unchanged.
  """
  @spec bounded(atom() | String.t(), String.t(), pos_integer(), pos_integer()) ::
          {:ok, String.t()} | {:error, String.t()}
  def bounded(field, text, min, max) do
    length = String.length(text)

    if length >= min and length <= max do
      case check(field, text) do
        :ok -> {:ok, text}
        {:error, _message} = error -> error
      end
    else
      {:error, "#{field} must be #{min}-#{max} characters, got #{length}"}
    end
  end
end
