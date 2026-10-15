defmodule AnkoleWeb.WorkplaceStream do
  @moduledoc "Streams committed conversation changes and live model text to Workplace."

  import Plug.Conn

  alias Ankole.AIGateway.Events
  alias Ankole.Conversations

  @ping_interval 15_000

  def open(conn, %{conversation: conversation, agent: agent, model_conversation_id: model_id}) do
    :ok = Conversations.subscribe(conversation.id)

    case Events.subscribe(agent.uid, model_id) do
      :ok ->
        stream(conn, conversation.id, agent.uid, model_id)

      {:error, _reason} ->
        :ok = Conversations.unsubscribe(conversation.id)
        {:error, :conversation_not_found}
    end
  end

  defp stream(conn, conversation_id, agent_uid, model_id) do
    try do
      conn =
        conn
        |> put_resp_content_type("text/event-stream")
        |> put_resp_header("cache-control", "no-cache")
        |> put_resp_header("x-accel-buffering", "no")
        |> send_chunked(200)

      {:ok, write(conn, ": ping\n\n", {conversation_id, agent_uid, model_id, nil}, next_ping())}
    after
      :ok = Events.unsubscribe(agent_uid, model_id)
      :ok = Conversations.unsubscribe(conversation_id)
    end
  end

  defp loop(conn, scope, ping_at) do
    remaining = ping_at - System.monotonic_time(:millisecond)

    if remaining > 0 do
      receive_event(conn, scope, ping_at, remaining)
    else
      write(conn, ": ping\n\n", scope, next_ping())
    end
  end

  defp receive_event(
         conn,
         {conversation_id, agent_uid, model_id, _response} = scope,
         ping_at,
         remaining
       ) do
    receive do
      {:conversation_event, ^conversation_id, event} when event in [:message, :status] ->
        write(conn, frame(event, %{}), scope, ping_at)

      {:ai_gateway_event, event, %{subject_uid: ^agent_uid, conversation_id: ^model_id} = gateway} ->
        write_gateway_event(conn, event, gateway, scope, ping_at)
    after
      remaining ->
        write(conn, ": ping\n\n", scope, next_ping())
    end
  end

  defp write_gateway_event(conn, :response_started, gateway, scope, ping_at) do
    {signal_ids, scope} = response_inputs(gateway, scope)

    write(
      conn,
      frame(:started, %{responseID: gateway.response_id, signalIDs: signal_ids}),
      scope,
      ping_at
    )
  end

  defp write_gateway_event(
         conn,
         :output_text_delta,
         %{response_id: id, payload: %{text: text}} = gateway,
         scope,
         ping_at
       )
       when is_binary(text) do
    {signal_ids, scope} = response_inputs(gateway, scope)

    write(
      conn,
      frame(:delta, %{responseID: id, signalIDs: signal_ids, text: text}),
      scope,
      ping_at
    )
  end

  defp write_gateway_event(conn, _event, _payload, scope, ping_at),
    do: loop(conn, scope, ping_at)

  defp response_inputs(%{response_id: id}, {_, _, _, {id, signal_ids}} = scope),
    do: {signal_ids, scope}

  defp response_inputs(gateway, {conversation_id, agent_uid, model_id, _response}) do
    signal_ids = Ankole.Sessions.response_signal_ids(gateway)
    {signal_ids, {conversation_id, agent_uid, model_id, {gateway.response_id, signal_ids}}}
  end

  defp write(conn, data, scope, ping_at) do
    case chunk(conn, data) do
      {:ok, conn} -> loop(conn, scope, ping_at)
      {:error, _closed} -> conn
    end
  end

  defp frame(event, data),
    do: ["event: ", to_string(event), "\ndata: ", Ankole.JSON.encode!(data), "\n\n"]

  defp next_ping, do: System.monotonic_time(:millisecond) + @ping_interval
end
