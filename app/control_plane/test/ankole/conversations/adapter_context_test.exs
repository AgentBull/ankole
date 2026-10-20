defmodule Ankole.Conversations.AdapterContextTest do
  use ExUnit.Case, async: true

  alias Ankole.Conversations.AdapterContext

  test "chat fan-out excludes identity consumers and preserves binding order" do
    consumers = [%{kind: :identity}, %{kind: :chat, id: 2}, %{kind: :chat, id: 1}]

    assert {:ok, [2, 1]} =
             AdapterContext.dispatch_chat(consumers, fn %{kind: :chat, id: id} -> {:ok, id} end)

    assert {:ok, []} = AdapterContext.dispatch_chat([%{kind: :identity}], fn _ -> flunk() end)
  end

  test "a failed binding does not suppress the other chat consumers" do
    consumers = for id <- 1..3, do: %{kind: :chat, id: id}

    assert {:error, :unavailable} =
             AdapterContext.dispatch_chat(consumers, fn %{id: id} ->
               send(self(), {:visited, id})
               if id == 2, do: {:error, :unavailable}, else: {:ok, id}
             end)

    assert_received {:visited, 1}
    assert_received {:visited, 2}
    assert_received {:visited, 3}
  end
end
