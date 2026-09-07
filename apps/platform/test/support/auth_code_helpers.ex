defmodule FluxVale.TestSupport.AuthCodeHelpers do
  @moduledoc false

  # Shared test helpers for the auth-code flow (test/support is
  # credo-exempt by config); tests own their preconditions.
  import ExUnit.Assertions

  alias FluxVale.Identity.AuthCode

  def mailbox_code do
    assert_receive {:email, %Swoosh.Email{text_body: body}},
                   1_000,
                   "expected the auth-code email to be delivered"

    [code] = Regex.run(~r/code is (\d{6})\./, body, capture: :all_but_first)
    code
  end

  def active_codes(email) do
    AuthCode
    |> Ash.Query.for_read(:active_for_email, %{email: email})
    |> Ash.Query.set_context(%{private: %{ash_authentication?: true}})
    |> Ash.read!()
  end

  def register_attempt(auth_code) do
    auth_code
    |> Ash.Changeset.for_update(:register_attempt)
    |> Ash.Changeset.set_context(%{private: %{ash_authentication?: true}})
    |> Ash.update()
  end

  def burn(auth_code) do
    auth_code
    |> Ash.Changeset.for_destroy(:burn)
    |> Ash.Changeset.set_context(%{private: %{ash_authentication?: true}})
    |> Ash.destroy()
  end
end
