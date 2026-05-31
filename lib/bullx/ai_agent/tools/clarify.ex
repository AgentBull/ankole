defmodule BullX.AIAgent.Tools.Clarify do
  @moduledoc """
  Implements the Agent tool that asks a human for clarification.

  The tool returns a structured event-like payload instead of blocking on a
  human response. The current runtime can then surface a request, simulate no
  response in tests, or report that clarification is unavailable for this
  invocation context.
  """

  alias BullX.AIAgent.Tools.Context

  @spec execute(map(), Context.t()) :: {:ok, map()}
  def execute(args, %Context{} = context) when is_map(args) do
    question =
      args
      |> string_arg(:question)
      |> String.trim()

    choices =
      args
      |> list_arg(:choices)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.take(4)

    case interaction_mode(context.metadata) do
      :requested ->
        {:ok,
         %{
           "kind" => "clarify.requested",
           "status" => "requested",
           "question" => question,
           "choices" => choices,
           "correlation_id" => context.idempotency_key
         }}

      :no_response ->
        {:ok,
         %{
           "kind" => "clarify.no_response",
           "status" => "no_response",
           "question" => question,
           "choices" => choices,
           "correlation_id" => context.idempotency_key
         }}

      :unavailable ->
        {:ok,
         %{
           "kind" => "clarify.unavailable",
           "status" => "unavailable",
           "question" => question,
           "choices" => choices
         }}
    end
  end

  defp interaction_mode(metadata) do
    cond do
      metadata_value(metadata, "clarify_mode") in ["no_response", :no_response] ->
        :no_response

      is_map(metadata_value(metadata, "reply_address")) ->
        :requested

      true ->
        :unavailable
    end
  end

  defp string_arg(args, key) do
    case Map.get(args, key) || Map.get(args, Atom.to_string(key)) do
      value when is_binary(value) -> value
      _value -> ""
    end
  end

  defp list_arg(args, key) do
    case Map.get(args, key) || Map.get(args, Atom.to_string(key)) do
      values when is_list(values) -> Enum.filter(values, &is_binary/1)
      _value -> []
    end
  end

  defp metadata_value(metadata, key) when is_map(metadata) do
    Map.get(metadata, key) || Map.get(metadata, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(metadata, key)
  end
end
