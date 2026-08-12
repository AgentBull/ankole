defmodule AnkoleWeb.ConsoleParams do
  @moduledoc """
  Query-parameter readers that the console list controllers share.
  """

  @doc """
  Reads the optional `agent` list filter.

  Returns the canonical lowercase agent UID. Returns `nil` for an absent or
  blank parameter, which selects every agent.
  """
  @spec agent_filter_param(map()) :: String.t() | nil
  def agent_filter_param(params) when is_map(params) do
    case Map.get(params, "agent") || Map.get(params, :agent) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> String.downcase(trimmed)
        end

      _value ->
        nil
    end
  end
end
