defmodule Ankole.Setup.BootstrapActivationCodeText do
  @moduledoc false

  @label "SETUP ACTIVATION CODE"
  @completed_message "Setup is already completed. No bootstrap activation code is active."
  @missing_message "Setup is open, but no bootstrap activation code is stored."

  @spec completed_message() :: String.t()
  def completed_message, do: @completed_message

  @spec missing_message() :: String.t()
  def missing_message, do: @missing_message

  @spec line(String.t()) :: String.t()
  def line(code) when is_binary(code), do: "#{@label}: #{code}"
end
