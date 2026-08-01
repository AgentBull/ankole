defmodule Ankole.AIGateway.MaxToolCallsTest do
  use ExUnit.Case, async: true

  alias Ankole.AIGateway.MaxToolCalls

  test "omitted and null limits stay unlimited, while native Responses passes through" do
    assert is_nil(MaxToolCalls.new(nil, :openai_chat_completions))
    assert is_nil(MaxToolCalls.new(nil, :openai_responses))
    assert is_nil(MaxToolCalls.new(2, :openai_responses))
    assert is_nil(MaxToolCalls.new(2, "openai_responses"))
    assert is_nil(MaxToolCalls.new(2, :hosted_responses))
    assert is_nil(MaxToolCalls.new(2, "hosted_responses"))

    assert %MaxToolCalls{limit: 2} = MaxToolCalls.new(2, :openai_chat_completions)
    assert %MaxToolCalls{limit: 2} = MaxToolCalls.new(2, :openai_responses, force: true)
  end

  test "ordinary function and custom calls never consume the built-in limit" do
    policy = MaxToolCalls.new(1, :anthropic_messages)

    policy =
      policy
      |> MaxToolCalls.observe_provider_event(output_item_done("function_call", "fc_1", 1))
      |> MaxToolCalls.observe_provider_event(output_item_done("custom_tool_call", "ctc_1", 2))

    refute MaxToolCalls.exhausted?(policy)
    assert MaxToolCalls.details(policy) == details(1, 0)
  end

  test "all current provider built-in call families consume one shared limit" do
    for type <- ~w(
          apply_patch_call
          code_interpreter_call
          computer_call
          file_search_call
          image_generation_call
          local_shell_call
          mcp_call
          mcp_list_tools
          shell_call
          web_search_call
        ) do
      policy =
        1
        |> MaxToolCalls.new(:anthropic_messages)
        |> MaxToolCalls.observe_provider_event(output_item_done(type, "#{type}-1", 1))

      assert MaxToolCalls.exhausted?(policy), "expected #{type} to consume the limit"
      assert MaxToolCalls.details(policy)["observed"] == 1
    end
  end

  test "zero is exhausted before any built-in effect starts" do
    policy = MaxToolCalls.new(0, :openai_chat_completions)

    assert MaxToolCalls.exhausted?(policy)
    assert MaxToolCalls.remaining(policy) == 0
    assert MaxToolCalls.details(policy) == details(0, 0)
  end

  test "later provider calls in one batch are ignored after the limit fills" do
    policy = MaxToolCalls.new(1, :openai_chat_completions)

    policy =
      policy
      |> MaxToolCalls.observe_provider_event(output_item_added("web_search_call", "ws_1", 0, 1))
      |> MaxToolCalls.observe_provider_event(output_item_added("web_search_call", "ws_2", 1, 2))
      |> MaxToolCalls.observe_provider_event(output_item_done("web_search_call", "ws_1", 3))

    assert MaxToolCalls.exhausted?(policy)

    policy =
      MaxToolCalls.observe_provider_event(
        policy,
        output_item_done("web_search_call", "ws_2", 4)
      )

    assert MaxToolCalls.exhausted?(policy)
    assert MaxToolCalls.details(policy) == details(1, 1)
  end

  test "duplicate provider lifecycle events remain idempotent" do
    policy = MaxToolCalls.new(1, :anthropic_messages)
    added = output_item_added("code_interpreter_call", "code_1", 0, 1)
    done = output_item_done("code_interpreter_call", "code_1", 2)

    policy =
      policy
      |> MaxToolCalls.observe_provider_event(added)
      |> MaxToolCalls.observe_provider_event(added)
      |> MaxToolCalls.observe_provider_event(done)
      |> MaxToolCalls.observe_provider_event(done)

    assert MaxToolCalls.exhausted?(policy)
    assert MaxToolCalls.details(policy) == details(1, 1)
  end

  test "output-index admission remaps to the stable provider item id" do
    policy = MaxToolCalls.new(1, :anthropic_messages)

    added = %{
      "type" => "response.output_item.added",
      "output_index" => 7,
      "item" => %{"type" => "web_search_call", "status" => "in_progress"}
    }

    done = %{
      "type" => "response.output_item.done",
      "output_index" => 7,
      "item" => %{"type" => "web_search_call", "id" => "ws_stable", "status" => "completed"}
    }

    policy =
      policy
      |> MaxToolCalls.observe_provider_event(added)
      |> MaxToolCalls.observe_provider_event(done)

    assert MaxToolCalls.exhausted?(policy)
    assert MapSet.size(policy.started) == 1
    assert MaxToolCalls.details(policy)["observed"] == 1
  end

  test "a gateway program is counted at admission without observing its output" do
    policy = MaxToolCalls.new(1, :openai_responses, force: true)
    program = program("prog_1", "return 1")
    event = %{"type" => "response.output_item.done", "item" => program}

    policy = MaxToolCalls.admit_gateway_event(policy, event)

    assert MaxToolCalls.item_admitted?(policy, program)
    assert MaxToolCalls.exhausted?(policy)
    assert MaxToolCalls.details(policy) == details(1, 1)
  end

  test "terminal-only server search admission is idempotent and scoped per provider round" do
    call = %{
      "type" => "tool_search_call",
      "id" => "reused",
      "call_id" => nil,
      "execution" => "server",
      "arguments" => %{"paths" => ["weather"]},
      "status" => "completed"
    }

    policy = MaxToolCalls.new(2, :openai_responses, force: true)

    policy =
      policy
      |> MaxToolCalls.admit_gateway_items([call], {:provider_round, 0})
      |> MaxToolCalls.admit_gateway_items([call], {:provider_round, 0})

    assert MaxToolCalls.details(policy)["observed"] == 1

    policy = MaxToolCalls.admit_gateway_items(policy, [call], {:provider_round, 1})

    assert MaxToolCalls.details(policy)["observed"] == 2
    assert MaxToolCalls.exhausted?(policy)
  end

  test "one admitted gateway effect excludes later calls in the same terminal" do
    policy = MaxToolCalls.new(1, :openai_responses, force: true)
    first = program("prog_1", "return 1")
    second = program("prog_2", "return 2")

    policy = MaxToolCalls.admit_gateway_items(policy, [first, second], :single_response)

    assert MaxToolCalls.item_admitted?(policy, first)
    refute MaxToolCalls.item_admitted?(policy, second)
    assert MaxToolCalls.exhausted?(policy)
    assert MaxToolCalls.details(policy) == details(1, 1)
  end

  test "client search is admitted directly and malformed gateway calls do not count" do
    policy = MaxToolCalls.new(1, :openai_responses, force: true)

    malformed = %{
      "type" => "tool_search_call",
      "id" => "ts_bad",
      "call_id" => nil,
      "execution" => "client",
      "arguments" => nil,
      "status" => "failed"
    }

    valid = %{
      "type" => "tool_search_call",
      "id" => "ts_1",
      "call_id" => "search_1",
      "execution" => "client",
      "arguments" => %{"query" => "weather"},
      "status" => "completed"
    }

    policy = MaxToolCalls.admit_gateway_items(policy, [malformed, valid], :single_response)

    assert MaxToolCalls.item_admitted?(policy, valid)
    assert MaxToolCalls.details(policy) == details(1, 1)
  end

  defp details(limit, observed) do
    %{"limit" => limit, "observed" => observed, "overshoot" => 0}
  end

  defp program(call_id, code) do
    %{
      "type" => "program",
      "call_id" => call_id,
      "code" => code,
      "fingerprint" => "fp-#{call_id}",
      "status" => "completed"
    }
  end

  defp output_item_added(type, id, output_index, sequence_number) do
    %{
      "type" => "response.output_item.added",
      "output_index" => output_index,
      "sequence_number" => sequence_number,
      "item" => %{"type" => type, "id" => id, "status" => "in_progress"}
    }
  end

  defp output_item_done(type, id, sequence_number) do
    %{
      "type" => "response.output_item.done",
      "sequence_number" => sequence_number,
      "item" => %{"type" => type, "id" => id, "status" => "completed"}
    }
  end
end
