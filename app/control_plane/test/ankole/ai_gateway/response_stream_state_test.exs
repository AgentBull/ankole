defmodule Ankole.AIGateway.ResponseStream.StateTest do
  use ExUnit.Case, async: true

  alias Ankole.AIGateway.HostedTools.StreamLoop
  alias Ankole.AIGateway.ResponseStream.State
  alias Ankole.AIGateway.ToolSearch

  defp state_variants do
    {:ok, provider_request, plan} =
      ToolSearch.plan(%{
        "model" => "gpt-5.6",
        "tools" => [%{"type" => "tool_search", "execution" => "client"}],
        "input" => []
      })

    [
      State.new("agent-test", %{}, %{"api_resolver" => "openai_responses"}),
      State.new("agent-test", %{}, %{"api_resolver" => "openai_responses"},
        tool_loop: %{plan: plan, provider_request: provider_request}
      )
    ]
  end

  describe "new/4" do
    test "always initializes a StreamLoop without retaining provider history on zero-effect responses" do
      state =
        State.new("agent-test", %{}, %{"api_resolver" => "openai_responses"},
          tool_loop: %{plan: nil, provider_request: %{"input" => [%{"type" => "message"}]}}
        )

      assert %StreamLoop{
               plan: nil,
               provider_request: nil,
               provider_items_rev: [],
               provider_history_count: 0,
               provider_history_item_bytes: 0
             } = state.tool_loop

      refute StreamLoop.gateway_effects?(state.tool_loop)
      refute State.initial_local_effect?(state)
      assert StreamLoop.round(state.tool_loop) == 0
      refute StreamLoop.multi_round?(state.tool_loop)
      assert StreamLoop.budget_scope(state.tool_loop) == {:provider_round, 0}
    end
  end

  describe "shared single-round event fixtures across zero-effect and hosted-tool responses" do
    test "uses the streamed items when the terminal envelope carries no output" do
      created = %{"type" => "response.created", "sequence_number" => 0, "response" => %{}}
      item = %{"type" => "message", "id" => "msg_1", "content" => "streamed"}

      done = %{
        "type" => "response.output_item.done",
        "sequence_number" => 1,
        "output_index" => 0,
        "item" => item
      }

      empty_terminal = %{
        "type" => "response.completed",
        "sequence_number" => 2,
        "response" => %{"id" => "resp_1", "status" => "completed", "output" => []}
      }

      terminal_items = [%{"type" => "message", "id" => "msg_1", "content" => "terminal"}]

      for state <- state_variants() do
        {:ok, state, [public_created], :continue} = State.observe(state, created, 0)
        {:ok, state, [public_done], :continue} = State.observe(state, done, 1)

        assert [^item] = State.round_output_items(state, empty_terminal)

        assert ^terminal_items =
                 State.round_output_items(state, %{
                   "type" => "response.completed",
                   "response" => %{"output" => terminal_items}
                 })

        assert [^item] = State.round_output_items(state, %{"type" => "response.failed"})

        {:ok, _state, [public_terminal], {:terminal, outcome, :keep_upstream}} =
          State.observe(state, empty_terminal, 2)

        assert Enum.map([public_created, public_done, public_terminal], & &1["sequence_number"]) ==
                 [0, 1, 2]

        assert public_terminal["response"]["output"] == [item]
        assert outcome.public_items == [item]
      end
    end

    test "keeps ordinary terminals intact and orders hosted-tool items before their terminal" do
      created = %{
        "type" => "response.created",
        "sequence_number" => 0,
        "response" => %{"id" => "resp_terminal_only"}
      }

      item = %{
        "type" => "message",
        "id" => "msg_terminal_only",
        "role" => "assistant",
        "status" => "completed",
        "content" => [%{"type" => "output_text", "text" => "only in terminal"}]
      }

      terminal = %{
        "type" => "response.completed",
        "sequence_number" => 1,
        "response" => %{
          "id" => "resp_terminal_only",
          "object" => "response",
          "status" => "completed",
          "output" => [item]
        }
      }

      expected_events = [
        [%{"type" => "response.completed", "sequence_number" => 1}],
        [
          %{
            "type" => "response.output_item.done",
            "sequence_number" => 1,
            "output_index" => 0,
            "item" => item
          },
          %{"type" => "response.completed", "sequence_number" => 2}
        ]
      ]

      for {state, expected} <- Enum.zip(state_variants(), expected_events) do
        {:ok, state, [public_created], :continue} = State.observe(state, created, 0)

        {:ok, _state, events, {:terminal, outcome, :keep_upstream}} =
          State.observe(state, terminal, 1)

        assert public_created["sequence_number"] == 0

        assert Enum.map(events, &Map.take(&1, ~w(type sequence_number output_index item))) ==
                 expected

        public_terminal = List.last(events)
        assert public_terminal["response"]["output"] == [item]
        assert outcome.public_items == [item]
      end
    end
  end
end
