defmodule Ankole.Principals.LocalPasswordResetText do
  @moduledoc """
  Operator-facing text for the local password rescue command.
  """

  @doc """
  Returns the success message with the new one-time password.
  """
  @spec success(String.t()) :: String.t()
  def success(initial_password) do
    """
    New one-time password: #{initial_password}

    The old password stopped working. The user must sign in with this
    password once and then set a new password.
    """
    |> String.trim_trailing()
  end

  @doc """
  Returns the error message for an email without a local account.
  """
  @spec no_account_message(String.t()) :: String.t()
  def no_account_message(email) do
    "no human user owns the email #{email}"
  end

  @doc """
  Returns the warning shown when no enabled local provider exists.
  """
  @spec provider_disabled_warning() :: String.t()
  def provider_disabled_warning do
    "Warning: local account sign-in is not enabled, so this password does not " <>
      "open a session until an operator enables the local identity provider."
  end
end
