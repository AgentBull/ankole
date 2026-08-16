defmodule Ankole.AIGateway.ResponseItemsTest do
  use ExUnit.Case, async: true

  alias Ankole.AIGateway.ResponseItems

  test "caller scope is part of tool-call identity" do
    items = [
      function_call("same", "direct"),
      function_call("same", "nested", caller("program-1")),
      function_output("same", "direct result"),
      function_output("same", "nested result", caller("program-1"))
    ]

    assert {:ok, ledger} = ResponseItems.reduce_many(items)
    assert ResponseItems.items(ledger) == items
  end

  test "explicit direct caller has direct identity and rejects ambiguous fields" do
    direct = function_call("direct-1", "lookup", %{"type" => "direct"})
    output = function_output("direct-1", "ok", %{"type" => "direct"})

    assert {:ok, _ledger} = ResponseItems.reduce_many([direct, output])

    assert ResponseItems.resolved_pair_keys([direct, output]) == [
             {:call, :direct, "direct-1"},
             {:call, :direct, "direct-1"}
           ]

    bad_direct =
      function_call("bad-direct", "lookup", %{
        "type" => "direct",
        "caller_id" => "forged"
      })

    bad_program =
      function_call("bad-program", "lookup", %{
        "type" => "program",
        "caller_id" => "program-1",
        "unexpected" => true
      })

    for item <- [bad_direct, bad_program] do
      assert ResponseItems.incomplete_call?(item)
      call_id = item["call_id"]

      assert {:error, {:incomplete_call_item, "function_call", ^call_id}} =
               ResponseItems.validate_executable_call(item)
    end
  end

  test "an unscoped output never satisfies a program-scoped call" do
    assert {:error, {:orphan_call_output, {:call, :direct, "same"}, "function_call_output"}} =
             ResponseItems.reduce_many([
               function_call("same", "nested", caller("program-1")),
               function_output("same", "wrong scope")
             ])
  end

  test "client pair validation owns caller, type, and executable semantics" do
    nested = function_call("same", "nested", caller("program-1"))
    nested_output = function_output("same", "ok", caller("program-1"))

    assert :ok = ResponseItems.validate_client_call_output(nested, nested_output)

    assert {:error, :pair_mismatch} =
             ResponseItems.validate_client_call_output(
               nested,
               function_output("same", "wrong scope")
             )

    assert {:error, :non_executable_call} =
             ResponseItems.validate_client_call_output(
               %{nested | "status" => "in_progress"},
               nested_output
             )
  end

  test "call and output types must match" do
    assert {:error, {:mismatched_call_output, {:call, :direct, "call-1"}, "custom_tool_call"}} =
             ResponseItems.reduce_many([
               function_call("call-1", "lookup"),
               %{
                 "type" => "custom_tool_call_output",
                 "call_id" => "call-1",
                 "output" => "wrong pair"
               }
             ])
  end

  test "identical replay deduplicates while a conflicting replay fails" do
    call = function_call("call-1", "lookup")

    assert {:ok, ledger, :inserted} = ResponseItems.reduce(ResponseItems.new(), call)
    assert {:ok, ^ledger, :duplicate} = ResponseItems.reduce(ledger, call)

    assert {:error,
            {:conflicting_call_pair, {:call, :direct, "call-1"}, "function_call", "function_call"}} =
             ResponseItems.reduce(ledger, %{call | "name" => "different"})
  end

  test "server tool-search pairs by FIFO when provider call ids are null" do
    call = %{
      "id" => "provider-item-call",
      "type" => "tool_search_call",
      "execution" => "server",
      "call_id" => nil,
      "arguments" => %{"paths" => ["weather"]},
      "status" => "completed"
    }

    output = %{
      "id" => "provider-item-output",
      "type" => "tool_search_output",
      "execution" => "server",
      "call_id" => nil,
      "tools" => [],
      "status" => "completed"
    }

    assert {:ok, _ledger} = ResponseItems.reduce_many([call, output])
    refute ResponseItems.safe_boundary?([call], [output])
    assert ResponseItems.safe_boundary?([], [call, output])
    assert ResponseItems.safe_boundary?([call, output], [])
  end

  test "all Responses call and output families share the canonical pair ledger" do
    pairs = [
      {%{
         "type" => "computer_call",
         "call_id" => "computer-1",
         "status" => "completed",
         "pending_safety_checks" => []
       },
       %{
         "type" => "computer_call_output",
         "call_id" => "computer-1",
         "output" => %{
           "type" => "computer_screenshot",
           "image_url" => "data:image/png;base64,eA=="
         }
       }},
      {%{
         "type" => "local_shell_call",
         "call_id" => "local-1",
         "status" => "completed",
         "action" => %{"type" => "exec", "command" => ["true"], "env" => %{}}
       }, %{"type" => "local_shell_call_output", "id" => "local-1", "output" => "{}"}},
      {%{
         "type" => "shell_call",
         "call_id" => "shell-1",
         "status" => "completed",
         "action" => %{"commands" => ["true"]}
       }, %{"type" => "shell_call_output", "call_id" => "shell-1", "output" => []}},
      {%{
         "type" => "apply_patch_call",
         "call_id" => "patch-1",
         "status" => "completed",
         "operation" => %{"type" => "delete_file", "path" => "old.txt"}
       },
       %{
         "type" => "apply_patch_call_output",
         "call_id" => "patch-1",
         "status" => "completed"
       }},
      {%{
         "type" => "mcp_approval_request",
         "id" => "approval-1",
         "arguments" => "{}",
         "name" => "lookup",
         "server_label" => "inventory"
       },
       %{
         "type" => "mcp_approval_response",
         "approval_request_id" => "approval-1",
         "approve" => true
       }}
    ]

    Enum.each(pairs, fn {call, output} ->
      assert ResponseItems.call_item?(call)
      assert ResponseItems.output_item?(output)
      assert ResponseItems.pair_key(call) == ResponseItems.pair_key(output)
      assert {:ok, _ledger} = ResponseItems.reduce_many([call, output])
      refute ResponseItems.safe_boundary?([call], [output])
      assert ResponseItems.safe_boundary?([call, output], [])
    end)
  end

  test "the canonical registry owns exceptional wire pair fields" do
    assert ResponseItems.pair_identity_field(%{"type" => "function_call"}) == "call_id"

    assert ResponseItems.pair_identity_field(%{"type" => "local_shell_call_output"}) == "id"

    assert ResponseItems.pair_identity_field(%{"type" => "mcp_approval_request"}) == "id"

    assert ResponseItems.pair_identity_field(%{"type" => "mcp_approval_response"}) ==
             "approval_request_id"

    assert ResponseItems.pair_identity_field(%{
             "type" => "future_provider_call",
             "call_id" => "future-1"
           }) == "call_id"

    assert ResponseItems.pair_identity_field(%{"type" => "message", "id" => "msg-1"}) == nil
  end

  test "shell and apply-patch pairs include the program caller" do
    families = [
      {%{
         "type" => "shell_call",
         "call_id" => "same",
         "status" => "completed",
         "action" => %{"commands" => ["true"]}
       }, %{"type" => "shell_call_output", "call_id" => "same", "output" => []}},
      {%{
         "type" => "apply_patch_call",
         "call_id" => "same",
         "status" => "completed",
         "operation" => %{"type" => "delete_file", "path" => "old.txt"}
       }, %{"type" => "apply_patch_call_output", "call_id" => "same", "status" => "completed"}}
    ]

    for {base_call, base_output} <- families do
      call_1 = Map.put(base_call, "caller", caller("program-1"))
      call_2 = Map.put(base_call, "caller", caller("program-2"))
      output_1 = Map.put(base_output, "caller", caller("program-1"))
      output_2 = Map.put(base_output, "caller", caller("program-2"))

      refute ResponseItems.pair_key(call_1) == ResponseItems.pair_key(call_2)
      assert ResponseItems.pair_key(call_1) == ResponseItems.pair_key(output_1)
      assert {:ok, _ledger} = ResponseItems.reduce_many([call_1, call_2, output_1, output_2])

      assert {:error, {:orphan_call_output, pair_key, output_type}} =
               ResponseItems.reduce_many([call_1, output_2])

      assert pair_key == ResponseItems.pair_key(output_2)
      assert output_type == base_output["type"]

      assert {:error, {:orphan_call_output, direct_key, ^output_type}} =
               ResponseItems.reduce_many([call_1, base_output])

      assert direct_key == ResponseItems.pair_key(base_output)

      invalid_call =
        Map.put(base_call, "caller", %{
          "type" => "program",
          "caller_id" => "",
          "extra" => true
        })

      refute ResponseItems.executable_call?(invalid_call)

      invalid_output = Map.put(base_output, "caller", %{"type" => "direct", "extra" => true})

      assert {:error, {:invalid_paired_output, ^output_type}} =
               ResponseItems.reduce_many([base_call, invalid_output])
    end
  end

  test "paired built-ins require their replay payload" do
    pairs = [
      {%{
         "type" => "computer_call",
         "call_id" => "computer",
         "pending_safety_checks" => []
       },
       %{
         "type" => "computer_call_output",
         "call_id" => "computer",
         "output" => %{
           "type" => "computer_screenshot",
           "image_url" => "data:image/png;base64,eA=="
         }
       }},
      {%{"type" => "local_shell_call", "call_id" => "local", "action" => %{}},
       %{"type" => "local_shell_call_output", "id" => "local", "output" => "{}"}},
      {%{"type" => "shell_call", "call_id" => "shell", "action" => %{}},
       %{"type" => "shell_call_output", "call_id" => "shell", "output" => []}},
      {%{"type" => "apply_patch_call", "call_id" => "patch", "operation" => %{}},
       %{
         "type" => "apply_patch_call_output",
         "call_id" => "patch",
         "status" => "failed"
       }},
      {%{
         "type" => "mcp_approval_request",
         "id" => "approval",
         "arguments" => "{}",
         "name" => "lookup",
         "server_label" => "inventory"
       },
       %{
         "type" => "mcp_approval_response",
         "approval_request_id" => "approval",
         "approve" => false
       }}
    ]

    for {call, output} <- pairs do
      assert ResponseItems.executable_call?(call)
      assert {:ok, _ledger} = ResponseItems.reduce_many([call, output])

      missing_call_payload =
        Map.drop(call, [
          "pending_safety_checks",
          "action",
          "operation",
          "arguments",
          "name",
          "server_label"
        ])

      refute ResponseItems.executable_call?(missing_call_payload)

      missing_output_payload =
        Map.drop(output, ["output", "status", "approve"])

      assert {:error, {:invalid_paired_output, output_type}} =
               ResponseItems.reduce_many([call, missing_output_payload])

      assert output_type == output["type"]
    end
  end

  test "client outputs require an OpenAI-compatible output value" do
    call = function_call("call-output", "lookup")

    valid_values = [
      "ok",
      [],
      [%{"type" => "input_text", "text" => "ok"}],
      [%{"type" => "input_image", "image_url" => "data:image/png;base64,eA=="}],
      [%{"type" => "input_file", "file_id" => "file_1"}]
    ]

    for output <- valid_values do
      assert {:ok, _ledger} =
               ResponseItems.reduce_many([call, function_output("call-output", output)])
    end

    for output <- [nil, %{}, 42, [%{"type" => "input_text"}], [%{"type" => "unknown"}]] do
      item = function_output("call-output", output)

      assert {:error, {:invalid_tool_call_output, "call-output"}} =
               ResponseItems.reduce_many([call, item])
    end

    missing = Map.delete(function_output("call-output", "ok"), "output")

    assert {:error, {:invalid_tool_call_output, "call-output"}} =
             ResponseItems.reduce_many([call, missing])
  end

  test "resolved pair keys preserve caller scope and hosted search FIFO" do
    direct = function_call("same", "direct")
    nested = function_call("same", "nested", caller("program-1"))

    search_call = %{
      "type" => "tool_search_call",
      "execution" => "server",
      "call_id" => nil,
      "status" => "completed",
      "arguments" => %{"paths" => ["crm"]}
    }

    search_output = %{
      "type" => "tool_search_output",
      "execution" => "server",
      "call_id" => nil,
      "status" => "completed",
      "tools" => []
    }

    assert [
             {:call, :direct, "same"},
             {:call, {:program, "program-1"}, "same"},
             search_pair,
             search_pair
           ] =
             ResponseItems.resolved_pair_keys([
               direct,
               nested,
               search_call,
               search_output
             ])
  end

  test "managed history analysis leaves direct stateful tool results opaque" do
    direct_output = function_output("stored-call", "ok")
    history = ResponseItems.analyze_history([direct_output])

    assert history.error == nil
    assert ResponseItems.items(history.ledger) == []
    assert [%{item: ^direct_output, managed?: false, pair_key: nil}] = history.entries
  end

  test "managed history analysis owns server search FIFO and program groups" do
    search_call = %{
      "type" => "tool_search_call",
      "execution" => "server",
      "call_id" => nil,
      "status" => "completed",
      "arguments" => %{"paths" => ["crm"]}
    }

    search_output = %{
      "type" => "tool_search_output",
      "execution" => "server",
      "call_id" => nil,
      "status" => "completed",
      "tools" => []
    }

    root = program("program-history")
    child = function_call("child-history", "lookup", caller("program-history"))
    child_output = function_output("child-history", "ok", caller("program-history"))

    history =
      ResponseItems.analyze_history([
        search_call,
        search_output,
        root,
        child,
        child_output
      ])

    assert history.error == nil

    assert [%{pair_key: search_key, output: %{item: ^search_output}}] =
             ResponseItems.search_pairs(history.ledger)

    assert {:search, :server, {:ordinal, 0}} = search_key

    assert [group] = ResponseItems.program_groups(history.ledger)
    assert group.call_id == "program-history"
    assert group.root.item == root
    assert [%{call: %{item: ^child}, output: %{item: ^child_output}}] = group.children
  end

  test "program aggregate cannot be split from its nested calls" do
    program = program("program-1")
    child = function_call("child-1", "lookup", caller("program-1"))
    child_output = function_output("child-1", "result", caller("program-1"))
    output = program_output("program-1")
    items = [program, child, child_output, output]

    refute ResponseItems.safe_boundary?([program], [child, child_output, output])
    refute ResponseItems.safe_boundary?([program, child, child_output], [output])
    assert ResponseItems.safe_boundary?([], items)
    assert ResponseItems.safe_boundary?(items, [])
  end

  test "a legacy unscoped nested output cannot pair but does not poison a closed program forever" do
    root = program("program-1")
    child = function_call("child-1", "lookup", caller("program-1"))
    malformed_output = function_output("child-1", "legacy missing caller")
    output = program_output("program-1")
    items = [root, child, malformed_output, output]

    assert {:error, {:orphan_call_output, {:call, :direct, "child-1"}, "function_call_output"}} =
             ResponseItems.reduce_many(items)

    refute ResponseItems.safe_boundary?([root, child], [malformed_output, output])
    assert ResponseItems.safe_boundary?(items, [])
  end

  test "a nested call is executable only with a complete owning program" do
    child = function_call("child-1", "lookup", caller("program-1"))

    assert {:ok, orphan_ledger} = ResponseItems.reduce_many([child])
    refute ResponseItems.executable_in_ledger?(orphan_ledger, child)

    assert {:ok, program_ledger} = ResponseItems.reduce_many([program("program-1"), child])
    assert ResponseItems.executable_in_ledger?(program_ledger, child)
  end

  test "multiple completed programs remain independent aggregates" do
    first = [program("program-1"), program_output("program-1")]
    second = [program("program-2"), program_output("program-2")]

    assert ResponseItems.safe_boundary?(first, second)
  end

  test "untyped Responses role and content items remain valid compaction boundaries" do
    items = [
      %{
        "role" => "user",
        "content" => [%{"type" => "input_text", "text" => "hello"}]
      },
      %{
        "role" => "assistant",
        "content" => [%{"type" => "output_text", "text" => "hi"}]
      }
    ]

    assert {:ok, ledger} = ResponseItems.reduce_many(items)
    assert ResponseItems.items(ledger) == items
    assert ResponseItems.safe_boundary?([hd(items)], [List.last(items)])
  end

  test "physical duplicate occurrences cannot hide a split call pair" do
    call = function_call("call-1", "lookup")
    output = function_output("call-1", "result")

    refute ResponseItems.safe_boundary?([call, call], [output])
    refute ResponseItems.safe_boundary?([call, output], [output])

    assert ResponseItems.safe_boundary?(
             [call, output],
             [call, output]
           )
  end

  test "an incomplete program is retained but never executable" do
    partial = %{
      "type" => "program",
      "call_id" => "program-1",
      "code" => "text('draft')",
      "status" => "in_progress"
    }

    refute ResponseItems.executable_call?(partial)
    assert ResponseItems.incomplete_call?(partial)

    assert {:error, {:incomplete_call_item, "program", "program-1"}} =
             ResponseItems.validate_executable_call(partial)

    assert {:ok, _ledger} = ResponseItems.reduce_many([partial])
    assert ResponseItems.safe_boundary?([], [partial])
    refute ResponseItems.safe_boundary?([partial], [])
  end

  test "loaded-tool output stays with a later program that may depend on it" do
    search_call = %{
      "type" => "tool_search_call",
      "execution" => "client",
      "call_id" => "search-1",
      "arguments" => %{"query" => "lookup"},
      "status" => "completed"
    }

    search_output = %{
      "type" => "tool_search_output",
      "execution" => "client",
      "call_id" => "search-1",
      "tools" => [%{"type" => "function", "name" => "lookup"}],
      "status" => "completed"
    }

    later_program = [program("program-1"), program_output("program-1")]

    refute ResponseItems.safe_boundary?(
             [search_call, search_output],
             later_program
           )
  end

  test "all current built-in declarations share the tool budget registry" do
    types = ~w(
      apply_patch
      code_interpreter
      computer
      computer_use_preview
      file_search
      image_generation
      local_shell
      mcp
      programmatic_tool_calling
      shell
      tool_search
      web_search
      web_search_2025_08_26
      web_search_preview
      web_search_preview_2025_03_11
    )

    assert Enum.all?(types, &ResponseItems.budgeted_tool_declaration?(%{"type" => &1}))
    assert Enum.all?(types, &ResponseItems.budgeted_tool_choice?(%{"type" => &1}))
    assert ResponseItems.budgeted_tool_choice?(%{"type" => "computer_use"})
    refute ResponseItems.budgeted_tool_declaration?(%{"type" => "computer_use"})
    refute ResponseItems.budgeted_tool_declaration?(%{"type" => "function"})
    refute ResponseItems.budgeted_tool_choice?(%{"type" => "function"})
  end

  test "an AIGateway-minted item identity never reaches a Provider" do
    minted = ResponseItems.ankole_identity("item", "0f4a2c")

    assert ResponseItems.ankole_identity?(minted)
    refute ResponseItems.ankole_identity?("rs_68a7f0c1")
    refute ResponseItems.ankole_identity?("msg_0f4a")

    input = [
      %{"id" => minted, "type" => "reasoning", "encrypted_content" => "sealed"},
      %{"id" => "rs_68a7f0c1", "type" => "reasoning", "encrypted_content" => "sealed"},
      function_call("call_1", "write_file")
    ]

    assert [minted_item, provider_item, call_item] = ResponseItems.drop_ankole_item_id(input)

    # A minted ID names no Provider object, so it goes; the Provider's own ID
    # stays, and the pair identity is untouched because it addresses nothing
    # outside this request.
    refute Map.has_key?(minted_item, "id")
    assert minted_item["encrypted_content"] == "sealed"
    assert provider_item["id"] == "rs_68a7f0c1"
    assert call_item["call_id"] == "call_1"
  end

  defp function_call(call_id, name, caller \\ nil) do
    %{
      "type" => "function_call",
      "call_id" => call_id,
      "name" => name,
      "arguments" => "{}",
      "status" => "completed"
    }
    |> maybe_put_caller(caller)
  end

  defp function_output(call_id, output, caller \\ nil) do
    %{
      "type" => "function_call_output",
      "call_id" => call_id,
      "output" => output
    }
    |> maybe_put_caller(caller)
  end

  defp program(call_id) do
    %{
      "type" => "program",
      "call_id" => call_id,
      "code" => "text('done')",
      "fingerprint" => "sha256:contract",
      "status" => "completed"
    }
  end

  defp program_output(call_id) do
    %{
      "type" => "program_output",
      "call_id" => call_id,
      "result" => ~s({"status":"completed","output":[]}),
      "status" => "completed"
    }
  end

  defp caller(program_id), do: %{"type" => "program", "caller_id" => program_id}

  defp maybe_put_caller(item, nil), do: item
  defp maybe_put_caller(item, caller), do: Map.put(item, "caller", caller)
end
