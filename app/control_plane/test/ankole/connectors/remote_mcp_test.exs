defmodule Ankole.Connectors.RemoteMCPTest do
  use ExUnit.Case, async: false
  alias Ankole.Connectors.RemoteMCP

  test "the expiry sweep removes only connections past their deadline" do
    now = System.monotonic_time(:millisecond)
    expired = {Ecto.UUID.generate(), "https://expired.example/mcp"}
    live = {Ecto.UUID.generate(), "https://live.example/mcp"}
    on_exit(fn -> Enum.each([expired, live], &:ets.delete(RemoteMCP, &1)) end)

    :ets.insert(RemoteMCP, {expired, %{session: nil}, now - 1})
    :ets.insert(RemoteMCP, {live, %{session: nil, tools: [%{"name" => "lookup"}]}, now + 60_000})

    send(RemoteMCP, :expire)
    :sys.get_state(RemoteMCP)

    assert :ets.lookup(RemoteMCP, expired) == []
    assert [{^live, %{tools: [%{"name" => "lookup"}]}, _expires}] = :ets.lookup(RemoteMCP, live)
  end
end
