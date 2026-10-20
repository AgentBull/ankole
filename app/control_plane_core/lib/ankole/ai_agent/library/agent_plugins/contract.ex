defmodule Ankole.AIAgent.Library.AgentPlugins.Contract do
  @moduledoc false

  @identifier ~r/\A[a-z][a-z0-9_-]{0,63}\z/

  @spec validate_identifier(term()) :: :ok | {:error, :invalid_identifier}
  def validate_identifier(value) when is_binary(value) do
    if Regex.match?(@identifier, value), do: :ok, else: {:error, :invalid_identifier}
  end

  def validate_identifier(_value), do: {:error, :invalid_identifier}
end
