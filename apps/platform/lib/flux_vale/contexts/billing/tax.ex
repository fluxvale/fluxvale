defmodule FluxVale.Billing.Tax do
  @moduledoc """
  The checkout tax layer's shared money math and buyer-evidence rules
  (#138, ADR-0029 Am. 3 gate 2).

  Prepaid credits are a single-purpose voucher (the settled #138 stance):
  VAT is collected at top-up on top of the credit value —
  `Topup.amount_cents` is the NET credit, `tax_cents` is the VAT on it,
  and the gateway is charged the GROSS (net + VAT).

  Every consumer of the formula (the wizard's display, StartTopup's
  default derivation) calls `tax_cents/2` — the half-up-to-the-cent
  rounding lives in exactly one place.
  """

  # B2B reverse charge: a VAT number that passes this format check is the
  # recorded proof (the issue's settled rule). Real VIES validation is a
  # launch-gate item, not test-mode work.
  @vat_format ~r/^[A-Z]{2}[A-Z0-9]{2,12}$/

  @doc """
  VAT on `amount_cents` at `rate_bp`, half-up to the cent:
  `div(amount_cents * rate_bp + 5_000, 10_000)`. The +5_000 bias makes
  integer floor-division round exact halves up.
  """
  @spec tax_cents(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def tax_cents(amount_cents, rate_bp)
      when is_integer(amount_cents) and amount_cents >= 0 and is_integer(rate_bp) and
             rate_bp >= 0 and rate_bp <= 10_000 do
    div(amount_cents * rate_bp + 5_000, 10_000)
  end

  @doc """
  B2B reverse charge: business buyer whose VAT number matches the EU/UK
  shape (2-letter country prefix + 2–12 alphanumeric). When true the
  applied rate is 0 and `tax_cents` is 0 — the customer self-accounts.
  """
  @spec reverse_charge?(:consumer | :business, String.t() | nil) :: boolean()
  def reverse_charge?(:business, vat_number) when is_binary(vat_number),
    do: String.match?(vat_number, @vat_format)

  def reverse_charge?(_customer_type, _vat_number), do: false

  @doc """
  The OSS location evidence: the billing country matching the IP country
  exactly. A mismatch or a missing IP country is tolerated and recorded,
  never blocking — VPNs and roaming make IP a weak proof; the exact
  match is what counts as verified.
  """
  @spec location_verified?(String.t() | nil, String.t() | nil) :: boolean()
  def location_verified?(nil, _ip_country), do: false

  def location_verified?(billing_country, ip_country),
    do: billing_country == ip_country

  @doc """
  Basis points as a percent label for the VAT line: 1900 → "19",
  2550 → "25.5".
  """
  @spec percent_label(non_neg_integer()) :: String.t()
  def percent_label(rate_bp) when is_integer(rate_bp) and rate_bp >= 0 do
    whole = div(rate_bp, 100)
    part = rem(rate_bp, 100)

    if part == 0 do
      Integer.to_string(whole)
    else
      "#{whole}.#{trim_zero(part)}"
    end
  end

  # Basis-point fractions land on tenths in the shipped table (25.5%);
  # a trailing zero in the hundredths position is never a real digit.
  defp trim_zero(part) do
    part
    |> Integer.to_string()
    |> String.replace_trailing("0", "")
  end
end
