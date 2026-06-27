defmodule Ankole.ActorRuntime.ConversationSummaryBroker do
  @moduledoc """
  Commits a worker-produced conversation summary for the current turn.

  The worker owns summarization and coverage selection. This RPC only validates
  the turn fence and writes the database-owned transcript/turn state.
  """

  alias Ankole.ActorRuntime.CommitCoordinator
  alias Ankole.ActorRuntime.WorkerRouteAuth

  @spec handle_request(map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_request(request, route) when is_map(request) and is_binary(route) do
    request_id = text(request, "request_id") || "conversation-summary-#{Ecto.UUID.generate()}"

    with {:ok, turn} <- turn_ref(request),
         :ok <- WorkerRouteAuth.authorize_turn_route(turn, route, :write),
         {:ok, result} <-
           request
           |> Map.put("request_id", request_id)
           |> Map.put("turn", turn)
           |> CommitCoordinator.commit_conversation_summary() do
      {:ok, result_payload(request_id, result)}
    else
      {:error, reason} -> error(request_id, reason)
    end
  end

  def handle_request(_request, _route),
    do:
      {:error,
       %{
         "request_id" => "",
         "code" => "invalid_conversation_summary_commit_request",
         "message" => "invalid_conversation_summary_commit_request",
         "details_json" => %{}
       }}

  defp result_payload(request_id, result) when is_map(result) do
    %{
      "request_id" => request_id,
      "status" => result_status(result)
    }
    |> maybe_put("llm_turn_id", schema_id(Map.get(result, :llm_turn)))
    |> maybe_put("summary_message_id", schema_id(Map.get(result, :summary_message)))
    |> maybe_put("covered_message_ids", Map.get(result, :covered_message_ids))
  end

  defp schema_id(%{id: id}), do: id
  defp schema_id(_value), do: nil

  defp result_status(%{status: status}) when is_atom(status), do: Atom.to_string(status)
  defp result_status(%{status: status}) when is_binary(status), do: status
  defp result_status(_result), do: "committed"

  defp turn_ref(%{"turn" => turn}) when is_map(turn), do: {:ok, turn}
  defp turn_ref(%{turn: turn}) when is_map(turn), do: {:ok, stringify_keys(turn)}
  defp turn_ref(_request), do: {:error, :missing_turn_ref}

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) and is_map(value) ->
        {Atom.to_string(key), stringify_keys(value)}

      {key, value} when is_atom(key) ->
        {Atom.to_string(key), value}

      {key, value} when is_map(value) ->
        {key, stringify_keys(value)}

      pair ->
        pair
    end)
  end

  defp error(request_id, reason) do
    {:error,
     %{
       "request_id" => request_id,
       "code" => error_code(reason),
       "message" => error_message(reason),
       "details_json" => %{}
     }}
  end

  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code(_reason), do: "conversation_summary_commit_failed"

  defp error_message(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_message(reason), do: inspect(reason)

  defp text(map, key) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      value when is_binary(value) -> value
      _value -> nil
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
