defmodule Ankole.AIGateway.ResponseStream.StateTest do
  use ExUnit.Case, async: true

  alias Ankole.AIGateway.ResponseStream.State

  describe "round_output_items/2" do
    test "uses the streamed items when the terminal envelope carries no output" do
      state = State.new("agent-test", %{}, %{"api_resolver" => "openai_responses"})

      {:ok, state, _events, :continue} =
        State.observe(state, %{"type" => "response.created", "response" => %{}}, 1)

      item = %{"type" => "message", "id" => "msg_1", "content" => "streamed"}

      {:ok, state, _events, :continue} =
        State.observe(
          state,
          %{"type" => "response.output_item.done", "output_index" => 0, "item" => item},
          2
        )

      terminal = %{"type" => "response.completed", "response" => %{"output" => []}}
      assert [^item] = State.round_output_items(state, terminal)

      terminal_items = [%{"type" => "message", "id" => "msg_1", "content" => "terminal"}]

      assert ^terminal_items =
               State.round_output_items(state, %{
                 "type" => "response.completed",
                 "response" => %{"output" => terminal_items}
               })

      assert [^item] = State.round_output_items(state, %{"type" => "response.failed"})
    end
  end
end
