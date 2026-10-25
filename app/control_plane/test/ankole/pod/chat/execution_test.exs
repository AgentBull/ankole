defmodule Ankole.Pod.Chat.ExecutionTest do
  use ExUnit.Case, async: true
  alias Ankole.AIGateway.ProgrammaticToolCalling, as: PTC
  alias Ankole.Sessions.Presentation.Execution

  test "work history follows the durable tool journal and excludes repeated request items" do
    at = ~U[2026-10-25 01:00:00Z]

    call = %{
      "type" => "function_call",
      "call_id" => "read",
      "name" => "read_file",
      "arguments" => ~s({"path":"Roadmap"})
    }

    thought = %{
      "type" => "reasoning",
      "summary" => [%{"type" => "summary_text", "text" => "Check the source."}]
    }

    output = %{
      "type" => "function_call_output",
      "call_id" => "read",
      "output" => "Error: Permission denied"
    }

    first = row("first", [thought, call], at)

    journal = %{
      row("journal", [output], DateTime.add(at, 1, :second))
      | metadata: %{"tool_result_journal" => true, "request_item_count" => 1}
    }

    final = %{
      row(
        "final",
        [call, output, %{"type" => "output_text", "text" => "Cannot read it."}],
        DateTime.add(at, 2, :second)
      )
      | metadata: %{"request_item_count" => 2}
    }

    states = %{"journal" => %{results: %{"read" => %{"is_error" => true, "duration_ms" => 150}}}}
    summary = Execution.from_chain([final, journal, first], states)
    assert summary["thinking_summary"] == "Check the source."
    assert summary["duration_ms"] == 2_000

    assert [
             %{
               "id" => "read",
               "status" => "failed",
               "duration_ms" => 150,
               "output" => "Error: Permission denied"
             }
           ] = summary["steps"]
  end

  test "Brain and provider tool calls use the gateway's canonical item families" do
    at = ~U[2026-10-25 01:00:00Z]

    brain = %{
      "type" => "brain_call",
      "call_id" => "memory",
      "operation" => "brain.search",
      "arguments" => %{"query" => "Roadmap"},
      "status" => "completed"
    }

    output = %{
      "type" => "brain_output",
      "call_id" => "memory",
      "output" => %{"ok" => true, "results" => []}
    }

    search = %{
      "type" => "web_search_call",
      "id" => "search",
      "action" => %{"query" => "current releases"},
      "status" => "completed"
    }

    summary = Execution.from_chain([row("hosted", [brain, output, search], at)])

    assert [
             %{
               "id" => "memory",
               "tool" => "brain.search",
               "title" => "Search memory: Roadmap (0 results)",
               "status" => "completed"
             },
             %{"id" => "search", "tool" => "web_search_call"}
           ] = summary["steps"]
  end

  test "the persisted thought summary keeps its complete text" do
    text = String.duplicate("Reasoning summary. ", 1_000)
    thought = %{"type" => "reasoning", "summary" => [%{"type" => "summary_text", "text" => text}]}
    summary = Execution.from_chain([row("thought", [thought], ~U[2026-10-25 01:00:00Z])])
    assert summary["thinking_summary"] == text
  end

  test "the real command transcript keeps the Pod resource name instead of its opaque ID" do
    at = ~U[2026-10-25 01:00:00Z]
    page_id = "019a2b00-0000-7000-8000-000000000001"
    command = "ankole-pod pages.read '{\"id\":\"#{page_id}\"}'"

    items = [
      %{
        "type" => "function_call",
        "call_id" => "page",
        "name" => "command",
        "arguments" => Ankole.JSON.encode!(%{"command" => command})
      },
      %{
        "type" => "function_call_output",
        "call_id" => "page",
        "output" =>
          "exit_code=0\nduration=20ms\n" <>
            Ankole.JSON.encode!(%{
              "ok" => true,
              "result" => %{"page" => %{"id" => page_id, "title" => "Q4 roadmap"}}
            })
      }
    ]

    assert [%{"title" => "Read page: Q4 roadmap"}] =
             Execution.from_chain([row("pod-command", items, at)])["steps"]
  end

  test "resource titles and counts come from the durable result, without resolving resource IDs" do
    at = ~U[2026-10-25 01:00:00Z]
    page_id = "019a2b00-0000-7000-8000-000000000001"

    calls = [
      {"page", "pages.read", %{"page" => %{"title" => "Q4 roadmap"}}},
      {"schema", "database.schema", %{"table" => %{"name" => "Candidates"}}},
      {"table", "database.query", %{"records" => [%{}, %{}], "complete" => true}},
      {"denied", "pages.read", nil}
    ]

    items =
      Enum.flat_map(calls, fn {id, operation, output} ->
        command = "ankole-pod #{operation} '#{Ankole.JSON.encode!(%{"id" => page_id})}'"

        transcript =
          if output,
            do:
              "exit_code=0\nduration=20ms\n" <>
                Ankole.JSON.encode!(%{"ok" => true, "result" => output}),
            else: "exit_code=1\nduration=20ms\nPermission denied"

        [
          %{
            "type" => "function_call",
            "call_id" => id,
            "name" => "command",
            "arguments" => Ankole.JSON.encode!(%{"command" => command})
          },
          %{
            "type" => "function_call_output",
            "call_id" => id,
            "output" => transcript
          }
        ]
      end)

    summary = Execution.from_chain([row("resources", items, at)])

    assert Enum.map(summary["steps"], & &1["title"]) == [
             "Read page: Q4 roadmap",
             "Read table schema: Candidates",
             "Query table (2 rows)",
             "Read page"
           ]

    refute Enum.any?(summary["steps"], &String.contains?(&1["title"], page_id))
  end

  test "a missing tool result is stopped or failed, while a committed result stays completed" do
    at = ~U[2026-10-25 01:00:00Z]

    call = %{
      "type" => "function_call",
      "call_id" => "read",
      "name" => "read_file",
      "arguments" => ~s({"path":"report.md"}),
      "status" => "completed"
    }

    chain = [row("pending", [call], at)]
    assert [%{"status" => "stopped"}] = Execution.from_chain(chain, %{}, "stopped")["steps"]
    assert [%{"status" => "failed"}] = Execution.from_chain(chain, %{}, "failed")["steps"]

    output = %{"type" => "function_call_output", "call_id" => "read", "output" => "Done"}

    assert [%{"status" => "completed"}] =
             Execution.from_chain([row("done", [call, output], at)], %{}, "stopped")["steps"]
  end

  test "successful command output can contain error fields as business data" do
    at = ~U[2026-10-25 01:00:00Z]

    call = %{
      "type" => "function_call",
      "call_id" => "inspect",
      "name" => "command",
      "status" => "completed",
      "arguments" => Ankole.JSON.encode!(%{"command" => "cat report.json"})
    }

    output = %{
      "type" => "function_call_output",
      "call_id" => "inspect",
      "output" => "exit_code=0\nduration=20ms\n{\"ok\":false,\"is_error\":true}"
    }

    journal = %{row("journal", [output], at) | metadata: %{"tool_result_journal" => true}}

    results = %{
      "inspect" =>
        Ankole.Sessions.ToolResult.journal_fields(%Ankole.Sessions.ToolResult{
          is_error: false,
          duration_ms: 20
        })
    }

    assert [%{"status" => "completed", "duration_ms" => 20}] =
             Execution.from_chain([journal, row("call", [call], at)], %{
               "journal" => %{results: results}
             })["steps"]
  end

  test "program work uses the gateway producer's code, result and failed outcome" do
    at = ~U[2026-10-25 01:00:00Z]
    {:ok, plan} = PTC.load_bindings(PTC.new(true), [])

    completed = %{
      status: :completed,
      output: [%{kind: "text", value: "Report ready"}],
      pending_calls: [],
      error: nil
    }

    failed = PTC.failed_outcome("program_runtime_failed", "Runtime unavailable")

    items =
      Enum.flat_map([{"done", completed}, {"failed", failed}], fn {id, outcome} ->
        call = %{
          "type" => "function_call",
          "name" => "program",
          "call_id" => id,
          "status" => "completed",
          "arguments" => Ankole.JSON.encode!(%{"code" => ~s|text("Report ready")|})
        }

        {:ok, job} = PTC.job(plan, call)

        {:ok, [output], [_provider_output], false} =
          PTC.settle(plan, [job], [%{call_id: id, outcome: outcome}])

        [PTC.public_item(plan, call), output]
      end)

    assert [
             %{
               "id" => "done",
               "input" => ~s|text("Report ready")|,
               "output" => "Report ready",
               "status" => "completed"
             },
             %{"id" => "failed", "status" => "failed", "output" => error}
           ] = Execution.from_chain([row("programs", items, at)])["steps"]

    assert Ankole.JSON.decode!(error) == %{"error" => "Runtime unavailable", "output" => []}
  end

  test "custom work preserves its canonical text input" do
    at = ~U[2026-10-25 01:00:00Z]
    input = "*** Begin Patch\n*** Add File: report.md\n+Report\n*** End Patch"

    items = [
      %{
        "type" => "custom_tool_call",
        "name" => "apply_patch",
        "call_id" => "patch",
        "status" => "completed",
        "input" => input
      },
      %{"type" => "custom_tool_call_output", "call_id" => "patch", "output" => "Applied"}
    ]

    assert [%{"input" => ^input, "output" => "Applied", "status" => "completed"}] =
             Execution.from_chain([row("custom", items, at)])["steps"]
  end

  defp row(id, content, at),
    do: %{id: id, content: content, metadata: %{}, inserted_at: at, updated_at: at}
end
