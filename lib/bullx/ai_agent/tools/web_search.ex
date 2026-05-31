defmodule BullX.AIAgent.Tools.WebSearch do
  @moduledoc """
  Tool entry point for Agent web search.

  This module only normalizes LLM tool arguments and delegates provider choice
  to `BullX.AIAgent.Tools.Web`, so model-facing tool schemas stay independent
  of Exa/Tavily/SerpAPI adapter details.
  """

  alias BullX.AIAgent.Tools.Context
  alias BullX.AIAgent.Tools.Web

  @spec execute(map(), Context.t()) :: {:ok, map()} | {:error, BullX.AIAgent.Tools.Error.t()}
  def execute(args, %Context{} = context) when is_map(args) do
    query = args |> string_arg(:query) |> String.trim()
    limit = Web.clamp_limit(Map.get(args, :limit) || Map.get(args, "limit"))

    Web.search(%{query: query, limit: limit}, context.metadata)
  end

  defp string_arg(args, key) do
    case Map.get(args, key) || Map.get(args, Atom.to_string(key)) do
      value when is_binary(value) -> value
      _value -> ""
    end
  end
end
