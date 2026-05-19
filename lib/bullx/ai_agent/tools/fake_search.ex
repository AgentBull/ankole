defmodule BullX.AIAgent.Tools.FakeSearch do
  @moduledoc false

  alias BullX.AIAgent.Tools.Context

  @spec execute(map(), Context.t()) :: {:ok, map()}
  def execute(%{query: query}, %Context{} = context) when is_binary(query) do
    {:ok,
     %{
       "ok" => true,
       "tool" => "web_search",
       "query" => query,
       "idempotency_key" => context.idempotency_key,
       "results" => [
         %{
           "title" => "Fake result",
           "snippet" => "This is deterministic test data for #{query}."
         }
       ]
     }}
  end

  def execute(%{"query" => query}, %Context{} = context), do: execute(%{query: query}, context)
end
