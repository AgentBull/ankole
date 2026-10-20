defmodule AnkoleWeb.AppletRequest do
  @moduledoc "Connects HTTP cancellation to an Applet invocation without changing response semantics."
  alias Ankole.Pod.Applets.Invocation

  def await(conn, task) do
    socket = http1_socket(conn)

    try do
      if socket, do: arm(socket)
      {result, received} = receive_result(task, socket, [])
      conn = restore(conn, socket, received)
      {conn, result}
    after
      if socket, do: ThousandIsland.Socket.setopts(socket, active: false)
      Invocation.cancel(task)
    end
  end

  defp receive_result(task, socket, received) do
    ref = task.ref
    raw = if socket, do: socket.socket

    receive do
      {^ref, outcome} ->
        Process.demonitor(ref, [:flush])
        {{:ok, outcome}, received}

      {:DOWN, ^ref, :process, _, _} ->
        {{:error, :handler_error}, received}

      {closed, ^raw} when closed in [:tcp_closed, :ssl_closed] ->
        disconnected()

      {error, ^raw, _reason} when error in [:tcp_error, :ssl_error] ->
        disconnected()

      {:bandit, {:rst_stream, code}} ->
        raise Bandit.TransportError, error: {:rst_stream, code}

      {data, ^raw, bytes} when data in [:tcp, :ssl] ->
        # Preserve pipelined request bytes for Bandit's next request.
        arm(socket)
        receive_result(task, socket, [bytes | received])
    end
  end

  defp http1_socket(%{
         adapter: {Bandit.Adapter, %{transport: %Bandit.HTTP1.Socket{socket: socket}}}
       }),
       do: socket

  defp http1_socket(_), do: nil

  defp restore(conn, nil, _received), do: conn

  defp restore(%{adapter: {module, adapter}} = conn, socket, received) do
    ThousandIsland.Socket.setopts(socket, active: false)
    received = drain(socket.socket, received)

    transport = %{
      adapter.transport
      | buffer: IO.iodata_to_binary([adapter.transport.buffer | Enum.reverse(received)])
    }

    %{conn | adapter: {module, %{adapter | transport: transport}}}
  end

  defp drain(raw, received) do
    receive do
      {data, ^raw, bytes} when data in [:tcp, :ssl] -> drain(raw, [bytes | received])
      {closed, ^raw} when closed in [:tcp_closed, :ssl_closed] -> disconnected()
      {error, ^raw, _reason} when error in [:tcp_error, :ssl_error] -> disconnected()
    after
      0 -> received
    end
  end

  defp disconnected, do: raise(Bandit.TransportError, error: :closed)

  defp arm(socket) do
    case ThousandIsland.Socket.setopts(socket, active: :once) do
      :ok -> :ok
      {:error, _reason} -> disconnected()
    end
  end
end
