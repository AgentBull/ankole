defmodule Ankole.E2E.FakeWeCom.WebSocketHandler do
  @moduledoc false

  @behaviour WebSock

  alias Ankole.E2E.FakeWeCom.State

  @impl true
  def init(%{state: state}) do
    :ok = State.register_conn(state, self())
    {:ok, %{state: state}}
  end

  @impl true
  def handle_in({data, [opcode: :text]}, ws) do
    case Torque.decode(data) do
      {:ok, frame} when is_map(frame) ->
        case State.handle_client_frame(ws.state, frame) do
          [] ->
            {:ok, ws}

          replies ->
            {:push, Enum.map(replies, &{:text, Torque.encode!(&1)}), ws}
        end

      _other ->
        {:ok, ws}
    end
  end

  def handle_in(_message, ws), do: {:ok, ws}

  @impl true
  def handle_info({:push_frame, frame}, ws),
    do: {:push, {:text, Torque.encode!(frame)}, ws}

  def handle_info(:close_socket, ws), do: {:stop, :normal, ws}

  def handle_info(_message, ws), do: {:ok, ws}

  @impl true
  def terminate(_reason, _ws), do: :ok
end
