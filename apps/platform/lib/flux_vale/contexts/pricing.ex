defmodule FluxVale.Pricing do
  @moduledoc """
  Pricing: the priceable allocation sizes behind ADR-0028's flat monthly
  rate ("Kavita: $X/mo, done", #125). Reads are any signed-in actor (the
  price shows in every catalog/provisioning surface); mutation is
  platform-admin-only. Opts into AshAdmin (ADR-0027) like Catalog:
  price changes are business data, admin-editable without a deploy.
  """

  use Ash.Domain,
    otp_app: :flux_vale,
    extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource FluxVale.Pricing.Size
  end

  @doc """
  Integer US cents → `"$12.34"` (1 credit = 1 US cent, docs/product.md;
  display currency pinned by ADR-0029 Am. 1).
  """
  @spec format_usd(non_neg_integer()) :: String.t()
  def format_usd(cents) when is_integer(cents) and cents >= 0 do
    dollars = div(cents, 100)
    remainder = rem(cents, 100)
    formatted = :io_lib.format("~B.~2..0B", [dollars, remainder])
    body = IO.iodata_to_binary(formatted)

    "$" <> body
  end
end
