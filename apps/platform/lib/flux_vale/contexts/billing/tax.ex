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
  Whether the recorded IP country matches the billing country exactly —
  a recorded signal, never a verification: the header is whatever the
  edge forwarded (client-settable behind a bare proxy) and VPNs/roaming
  make IP weak either way. The billing address is the SOLE rate-deciding
  proof; this signal is recorded for the return's evidence trail, and a
  mismatch or a missing IP country never blocks the buyer.
  """
  @spec ip_matches_billing?(String.t() | nil, String.t() | nil) :: boolean()
  def ip_matches_billing?(nil, _ip_country), do: false

  def ip_matches_billing?(billing_country, ip_country),
    do: billing_country == ip_country

  @doc """
  Basis points as a percent label for the VAT line: 1900 → "19",
  2550 → "25.5", 5 → "0.05".
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

  # Basis points are hundredths of a percent — pad the fraction to two
  # digits before trimming trailing zeros, or 5 bp would mislabel as
  # "0.5" instead of "0.05".
  defp trim_zero(part) do
    part
    |> Integer.to_string()
    |> String.pad_leading(2, "0")
    |> String.replace_trailing("0", "")
  end
end
