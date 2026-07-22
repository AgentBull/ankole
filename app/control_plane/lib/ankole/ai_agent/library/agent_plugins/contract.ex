defmodule Ankole.AIAgent.Library.AgentPlugins.Contract do
  @moduledoc false

  @identifier ~r/\A[a-z][a-z0-9_-]{0,63}\z/
  @reasoning_efforts ~w(minimal low medium high xhigh)

  @spec reasoning_efforts() :: [String.t()]
  def reasoning_efforts, do: @reasoning_efforts

  @spec validate_identifier(term()) :: :ok | {:error, :invalid_identifier}
  def validate_identifier(value) when is_binary(value) do
    if Regex.match?(@identifier, value), do: :ok, else: {:error, :invalid_identifier}
  end

  def validate_identifier(_value), do: {:error, :invalid_identifier}
end
