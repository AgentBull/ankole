defmodule Ankole.Kernel.UniversalAIClientCancellationTest do
  use ExUnit.Case, async: false
  alias Ankole.Kernel.UniversalAIClient

  for mode <- [:raw, :model] do
    test "#{mode} request closes the real provider connection when its owner exits" do
      mode = unquote(mode)
      parent = self()
      reference = make_ref()

      {:ok, listener} =
        :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])

      {:ok, {_address, port}} = :inet.sockname(listener)

      server =
        Task.async(fn ->
          {:ok, socket} = :gen_tcp.accept(listener, 5_000)
          {:ok, _request} = :gen_tcp.recv(socket, 0, 5_000)
          send(parent, {reference, :connected})
          result = await_closed(socket)
          :gen_tcp.close(socket)
          result
        end)

      url = "http://127.0.0.1:#{port}/provider"
      owner = spawn(fn -> request(mode, url) end)
      monitor = Process.monitor(owner)

      try do
        assert_receive {^reference, :connected}, 5_000
        assert Process.alive?(owner)
        Process.exit(owner, :kill)
        assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}, 1_000
        # The upstream has sent no response. Closing must come from cancelling
        # native I/O, rather than a completed request or its 30-second timeout.
        assert Task.await(server, 2_000) == {:error, :closed}
      after
        Process.exit(owner, :kill)
        Task.shutdown(server, :brutal_kill)
        :gen_tcp.close(listener)
      end
    end
  end

  defp await_closed(socket) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, _remaining_request_bytes} -> await_closed(socket)
      result -> result
    end
  end

  defp request(:raw, url), do: UniversalAIClient.raw_get(url, timeout: timeout())

  defp request(:model, url) do
    UniversalAIClient.model_request(%{
      api_resolver: :openai_responses,
      upstream: %{
        method: "POST",
        url: url,
        headers: [{"content-type", "application/json"}],
        timeout: timeout(),
        transport: %{}
      },
      response_context: %{model: "test-model", request: %{"input" => "hello"}}
    })
  end

  defp timeout,
    do: %{connect_ms: 5_000, first_byte_ms: 30_000, idle_ms: 30_000, total_ms: 30_000}
end
