defmodule AnkoleWeb.AppletRequest do
  @moduledoc "Bounds waiting HTTP/1 input and cancels Applet invocations on disconnect."
  alias Ankole.Pod.Applets.Invocation

  @max_pipeline_bytes 1_048_576

  def await(conn, task) do
    transport = http1_transport(conn)
    socket = if transport, do: transport.socket

    try do
      remaining =
        if transport,
          do: @max_pipeline_bytes - IO.iodata_length(transport.buffer),
          else: @max_pipeline_bytes

      check_pipeline_budget!(socket, remaining)
      if socket, do: arm(socket)
      {result, received} = receive_result(task, socket, {[], remaining})
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
        received = retain(socket, bytes, received)
        arm(socket)
        receive_result(task, socket, received)
    end
  end

  defp http1_transport(%{
         adapter: {Bandit.Adapter, %{transport: %Bandit.HTTP1.Socket{} = transport}}
       }),
       do: transport

  defp http1_transport(_), do: nil

  defp restore(conn, nil, _received), do: conn

  defp restore(%{adapter: {module, adapter}} = conn, socket, received) do
    ThousandIsland.Socket.setopts(socket, active: false)
    received = drain(socket, received)

    transport = %{
      adapter.transport
      | buffer: IO.iodata_to_binary([adapter.transport.buffer | Enum.reverse(received)])
    }

    %{conn | adapter: {module, %{adapter | transport: transport}}}
  end

  defp drain(socket, {received, _remaining} = buffered) do
    raw = socket.socket

    receive do
      {data, ^raw, bytes} when data in [:tcp, :ssl] ->
        drain(socket, retain(socket, bytes, buffered))

      {closed, ^raw} when closed in [:tcp_closed, :ssl_closed] ->
        disconnected()

      {error, ^raw, _reason} when error in [:tcp_error, :ssl_error] ->
        disconnected()
    after
      0 -> received
    end
  end

  defp retain(socket, bytes, {received, remaining}) do
    remaining = remaining - byte_size(bytes)
    check_pipeline_budget!(socket, remaining)
    {[bytes | received], remaining}
  end

  defp check_pipeline_budget!(socket, remaining) when remaining < 0 do
    ThousandIsland.Socket.close(socket)
    disconnected()
  end

  defp check_pipeline_budget!(_socket, _remaining), do: :ok

  defp disconnected, do: raise(Bandit.TransportError, error: :closed)

  defp arm(socket) do
    case ThousandIsland.Socket.setopts(socket, active: :once) do
      :ok -> :ok
      {:error, _reason} -> disconnected()
    end
  end
end
