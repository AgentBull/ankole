defmodule Ankole.AIGateway.ReplayMemoryMigrationTest do
  use ExUnit.Case, async: true

  unless Code.ensure_loaded?(Ankole.Repo.Migrations.SeparateReplayMemory),
    do:
      Code.require_file(
        "../../../priv/repo/migrations/20261012000300_separate_replay_memory.exs",
        __DIR__
      )

  alias Ankole.Repo.Migrations.SeparateReplayMemory
  alias Ankole.AIGateway.HostedTools.Brain

  test "moves only recorded memory and preserves identical user-authored text and outputs" do
    pack = message("<recalled_memory>\nold memory\n</recalled_memory>")
    original = message("用户也写了 memory: concepts/source，保留原文")
    block = "<agent_environment_info>\nmemory: concepts/source\n</agent_environment_info>"

    injected =
      Map.update!(original, "content", &[%{"type" => "input_text", "text" => block} | &1])

    output = %{
      "type" => "message",
      "role" => "assistant",
      "content" => [%{"type" => "output_text", "text" => "Done"}]
    }

    metadata = %{
      "request_item_count" => 2,
      "brain_injection" => %{
        "items" => [0],
        "environment" => %{
          "item_index" => 1,
          "part_index" => 0,
          "offset" => 0,
          "length" => byte_size(block)
        }
      }
    }

    assert {[^original, ^output], converted} =
             SeparateReplayMemory.separate([pack, injected, output], metadata)

    assert converted["request_item_count"] == 1
    assert converted["brain_context_pack"] == [pack]
    assert converted["brain_pointer_lines"] == ["memory: concepts/source"]
    refute Map.has_key?(converted, "brain_injection")
    assert Brain.replay([original], converted) == [pack, injected]
  end

  test "uses byte offsets for the one-time migration and preserves the existing environment" do
    prefix = "<agent_environment_info>\n租户: 已知\n"
    pointers = "memory: concepts/source\n"
    suffix = "</agent_environment_info>"
    user = message(prefix <> pointers <> suffix)

    metadata = %{
      "brain_injection" => %{
        "items" => [],
        "environment" => %{
          "item_index" => 0,
          "part_index" => 0,
          "offset" => byte_size(prefix),
          "length" => byte_size(pointers)
        }
      }
    }

    assert {[original], converted} = SeparateReplayMemory.separate([user], metadata)
    assert original == message(prefix <> suffix)
    assert Brain.replay([original], converted) == [user]
    assert converted["brain_context_pack_claimed"]
  end

  test "preserves legacy pack positions between caller inputs and before output" do
    first = message("First caller input")
    pack = message("Opening memory")
    last = message("Last caller input")
    second_pack = message("More memory")
    output = %{"type" => "message", "role" => "assistant", "content" => []}

    metadata = %{
      "request_item_count" => 4,
      "brain_injection" => %{"items" => [1, 3]}
    }

    assert {[^first, ^last, ^output], converted} =
             SeparateReplayMemory.separate([first, pack, last, second_pack, output], metadata)

    assert converted["request_item_count"] == 2
    assert Brain.replay([first, last], converted) == [first, pack, last, second_pack]
  end

  defp message(text),
    do: %{
      "type" => "message",
      "role" => "user",
      "content" => [%{"type" => "input_text", "text" => text}]
    }
end
