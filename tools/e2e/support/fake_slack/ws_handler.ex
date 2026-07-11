defmodule Ankole.E2E.FakeSlack.WebSocketHandler do
  @moduledoc false

  @behaviour WebSock

  alias Ankole.E2E.FakeSlack.State

  @impl true
  def init(%{state: state}) do
    :ok = State.register_conn(state, self())
    send(self(), :hello)
    {:ok, %{state: state}}
  end

  @impl true
  def handle_in({data, [opcode: :text]}, ws) do
    case Torque.decode(data) do
      {:ok, %{"envelope_id" => envelope_id}} -> State.record_ack(ws.state, envelope_id)
      _other -> :ok
    end

    {:ok, ws}
  end

  def handle_in(_message, ws), do: {:ok, ws}

  @impl true
  def handle_info(:hello, ws) do
    hello = %{
      "type" => "hello",
      "num_connections" => 1,
      "connection_info" => %{"app_id" => "AFAKE"},
      "debug_info" => %{"approximate_connection_time" => 3600}
    }

    {:push, {:text, Torque.encode!(hello)}, ws}
  end

  def handle_info({:push_envelope, envelope}, ws),
    do: {:push, {:text, Torque.encode!(envelope)}, ws}

  def handle_info(_message, ws), do: {:ok, ws}

  @impl true
  def terminate(_reason, _ws), do: :ok
end
