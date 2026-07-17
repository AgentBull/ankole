defmodule Ankole.E2E.FakeDingTalk.WebSocketHandler do
  @moduledoc false

  @behaviour WebSock

  alias Ankole.E2E.FakeDingTalk.State

  @impl true
  def init(%{state: state}) do
    :ok = State.register_conn(state, self())
    {:ok, %{state: state}}
  end

  @impl true
  def handle_in({data, [opcode: :text]}, ws) do
    # The client responds to every SYSTEM/EVENT/CALLBACK frame with a response
    # frame that echoes the request messageId. Record it keyed by that id so the
    # test can assert the ack shape (opaque echo, SUCCESS/LATER, response map).
    case Torque.decode(data) do
      {:ok, %{"headers" => %{"messageId" => message_id}} = response} ->
        State.record_ack(ws.state, message_id, response)

      _other ->
        :ok
    end

    {:ok, ws}
  end

  def handle_in(_message, ws), do: {:ok, ws}

  @impl true
  def handle_info({:push_frame, frame}, ws),
    do: {:push, {:text, Torque.encode!(frame)}, ws}

  def handle_info(_message, ws), do: {:ok, ws}

  @impl true
  def terminate(_reason, _ws), do: :ok
end
