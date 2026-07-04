defmodule Ankole.E2E.FakeFeishu.WsHandler do
  @moduledoc """
  WebSock handler for one fake Feishu long connection.

  Decodes real PBBP2 frames from the client, answers application-level pings
  with pongs, and records event acks back into `FakeFeishu.State`. Event frames
  are pushed from State via `{:push_frames, [binary]}` messages.
  """

  @behaviour WebSock

  alias Ankole.E2E.FakeFeishu.State
  alias Ankole.JSON
  alias FeishuOpenAPI.WS.Frame

  @impl true
  def init(%{state: state, app_id: app_id}) do
    conn_id = System.unique_integer([:positive])
    :ok = State.register_conn(state, self(), conn_id, app_id)
    {:ok, %{state: state, conn_id: conn_id, app_id: app_id}}
  end

  @impl true
  def handle_in({data, [opcode: :binary]}, ws) do
    case Frame.decode(data) do
      {:ok, frame} -> route_frame(frame, ws)
      {:error, _reason} -> {:ok, ws}
    end
  end

  def handle_in(_message, ws), do: {:ok, ws}

  @impl true
  def handle_info({:push_frames, frame_bins}, ws) do
    {:push, Enum.map(frame_bins, &{:binary, &1}), ws}
  end

  def handle_info({:fake_feishu_close, code}, ws) do
    {:stop, :normal, code, ws}
  end

  def handle_info(_message, ws), do: {:ok, ws}

  @impl true
  def terminate(_reason, _ws), do: :ok

  defp route_frame(frame, ws) do
    case Frame.type(frame) do
      "ping" ->
        State.record_ping(ws.state, ws.conn_id)
        {:push, {:binary, Frame.encode(pong_for(frame))}, ws}

      "pong" ->
        {:ok, ws}

      _event_or_card ->
        record_ack(frame, ws)
        {:ok, ws}
    end
  end

  # The client acks an event by echoing the request frame identity (headers
  # incl. message_id plus biz_rt) with a `{"code": ...}` payload.
  defp record_ack(frame, ws) do
    with event_id when is_binary(event_id) <- Frame.message_id(frame),
         {:ok, %{"code" => code}} <- JSON.decode(frame.payload) do
      State.record_ack(ws.state, event_id, code)
    else
      _not_an_ack -> :ok
    end
  end

  defp pong_for(frame) do
    %Frame{
      method: 0,
      seq_id: frame.seq_id,
      log_id: frame.log_id,
      service: frame.service,
      headers: [{"type", "pong"}]
    }
  end
end
