defmodule Ankole.AIGateway.CompactionRenderTest do
  use ExUnit.Case, async: true

  alias Ankole.AIGateway.CompactionRender

  test "caps very large function call outputs" do
    rendered =
      CompactionRender.render_items([
        %{
          "type" => "function_call_output",
          "call_id" => "call_large",
          "output" => String.duplicate("x", 300_000)
        }
      ])

    assert rendered =~ "tokens elided"
    assert CompactionRender.approx_tokens(rendered) <= 2_100
  end

  test "uses local aliases instead of persisted function call ids" do
    call_id = "019f0000-0000-7000-8000-000000000001"

    rendered =
      CompactionRender.render_items([
        %{
          "type" => "function_call",
          "name" => "memory_open",
          "call_id" => call_id,
          "arguments" => ~s({"name":"Project Alpha"})
        },
        %{
          "type" => "function_call_output",
          "call_id" => call_id,
          "output" => ~s({"status":"ok"})
        }
      ])

    assert rendered =~ "function_call memory_open call_ref=call_1"
    assert rendered =~ "function_call_output call_ref=call_1"
    refute rendered =~ call_id
  end

  test "renders custom calls and outputs with one local alias" do
    call_id = "019f0000-0000-7000-8000-000000000002"

    rendered =
      CompactionRender.render_items([
        %{
          "type" => "custom_tool_call",
          "name" => "apply_patch",
          "call_id" => call_id,
          "input" => "*** Begin Patch\n*** Add File: report.md\n+done\n*** End Patch\n"
        },
        %{
          "type" => "custom_tool_call_output",
          "call_id" => call_id,
          "output" => "Done!"
        }
      ])

    assert rendered =~ "custom_tool_call apply_patch call_ref=call_1"
    assert rendered =~ "custom_tool_call_output call_ref=call_1"
    refute rendered =~ call_id
  end

  test "caps program code and output with one local alias" do
    call_id = "019f0000-0000-7000-8000-000000000003"

    rendered =
      CompactionRender.render_items([
        %{
          "type" => "program",
          "call_id" => call_id,
          "code" => String.duplicate("const result = await tools.market({});\n", 1_000)
        },
        %{
          "type" => "program_output",
          "call_id" => call_id,
          "status" => "completed",
          "result" => String.duplicate("x", 300_000)
        }
      ])

    assert rendered =~ "program call_ref=call_1"
    assert rendered =~ "program_output call_ref=call_1 status=completed"
    assert rendered =~ "tokens elided"
    refute rendered =~ call_id
    assert CompactionRender.approx_tokens(rendered) <= 2_700
  end

  test "renders hosted Tool Search pairs with an ordinal local alias" do
    rendered =
      CompactionRender.render_items([
        %{
          "type" => "tool_search_call",
          "execution" => "server",
          "call_id" => nil,
          "status" => "completed",
          "arguments" => %{"paths" => ["crm"]}
        },
        %{
          "type" => "tool_search_output",
          "execution" => "server",
          "call_id" => nil,
          "status" => "completed",
          "tools" => [
            %{
              "type" => "namespace",
              "name" => "crm",
              "tools" => [%{"type" => "function", "name" => "list_orders"}]
            }
          ]
        }
      ])

    assert rendered =~ "tool_search_call execution=server call_ref=call_1"
    assert rendered =~ ~s("paths":["crm"])
    assert rendered =~ "tool_search_output execution=server call_ref=call_1 status=completed"
    assert rendered =~ "list_orders"
  end

  test "renders every registered native call family instead of dropping its payload" do
    items = [
      %{
        "type" => "computer_call",
        "call_id" => "computer-secret",
        "status" => "completed",
        "action" => %{"type" => "click", "x" => 10, "y" => 20}
      },
      %{
        "type" => "computer_call_output",
        "call_id" => "computer-secret",
        "output" => %{"type" => "computer_screenshot"}
      },
      %{
        "type" => "local_shell_call",
        "call_id" => "shell-secret",
        "status" => "completed",
        "action" => %{"command" => "pwd"}
      },
      %{
        "type" => "local_shell_call_output",
        "id" => "shell-secret",
        "output" => "workspace"
      },
      %{
        "type" => "apply_patch_call",
        "call_id" => "patch-secret",
        "status" => "completed",
        "operation" => %{"type" => "update_file", "path" => "report.md"}
      },
      %{
        "type" => "apply_patch_call_output",
        "call_id" => "patch-secret",
        "output" => "Done"
      },
      %{
        "type" => "mcp_approval_request",
        "id" => "approval-secret",
        "name" => "send_message"
      },
      %{
        "type" => "mcp_approval_response",
        "approval_request_id" => "approval-secret",
        "approve" => true
      }
    ]

    rendered = CompactionRender.render_items(items)

    for type <- ~w(
          computer_call
          computer_call_output
          local_shell_call
          local_shell_call_output
          apply_patch_call
          apply_patch_call_output
          mcp_approval_request
          mcp_approval_response
        ) do
      assert rendered =~ "#{type} call_ref="
      refute rendered =~ "[#{type} omitted]"
    end

    assert rendered =~ "workspace"
    assert rendered =~ "report.md"
    assert rendered =~ ~s("approve":true)
    refute rendered =~ "computer-secret"
    refute rendered =~ "shell-secret"
    refute rendered =~ "patch-secret"
    refute rendered =~ "approval-secret"
  end

  test "does not collapse direct and program-scoped calls that reuse a call id" do
    rendered =
      CompactionRender.render_items([
        %{
          "type" => "function_call",
          "name" => "direct_lookup",
          "call_id" => "reused",
          "arguments" => "{}"
        },
        %{
          "type" => "function_call",
          "name" => "nested_lookup",
          "call_id" => "reused",
          "arguments" => "{}",
          "caller" => %{"type" => "program", "caller_id" => "program_1"}
        }
      ])

    assert rendered =~ "function_call direct_lookup call_ref=call_1"
    assert rendered =~ "function_call nested_lookup call_ref=call_2"
  end

  test "global budget elides oldest eligible items while preserving users and latest items" do
    items =
      for index <- 1..20 do
        if index == 3 do
          %{"type" => "message", "role" => "user", "content" => "user item survives"}
        else
          %{
            "type" => "message",
            "role" => "assistant",
            "content" => "assistant item #{index} " <> String.duplicate("wide ", 30)
          }
        end
      end

    rendered = CompactionRender.render_items(items, budget_tokens: 180)

    assert rendered =~ "older items elided"
    assert rendered =~ "user item survives"
    assert rendered =~ "assistant item 20"
    assert rendered =~ "assistant item 19"
  end

  test "budget rendering preserves elision runs and protected item order" do
    items = [
      %{"type" => "message", "role" => "assistant", "content" => "drop 1"},
      %{"type" => "message", "role" => "assistant", "content" => "drop 2"},
      %{"type" => "message", "role" => "user", "content" => "keep user"},
      %{"type" => "message", "role" => "assistant", "content" => "drop 4"},
      %{"type" => "message", "role" => "assistant", "content" => "drop 5"},
      %{"type" => "message", "role" => "assistant", "content" => "drop 6"},
      %{"type" => "message", "role" => "assistant", "content" => "keep latest 7"},
      %{"type" => "message", "role" => "assistant", "content" => "keep latest 8"}
    ]

    rendered = CompactionRender.render_items(items, budget_tokens: 1)

    assert rendered ==
             "...[2 older items elided]...\n" <>
               "<item index=\"3\">\nuser: keep user\n</item>\n\n" <>
               "...[3 older items elided]...\n" <>
               "<item index=\"7\">\nassistant: keep latest 7\n</item>\n\n" <>
               "<item index=\"8\">\nassistant: keep latest 8\n</item>\n"
  end

  test "budget rendering stops at the same exact partial elision boundary" do
    items =
      for index <- 1..8 do
        content =
          if index <= 2,
            do: "large #{index} " <> String.duplicate("x", 1_000),
            else: "small #{index}"

        %{"type" => "message", "role" => "assistant", "content" => content}
      end

    full = CompactionRender.render_items(items)
    first_two = CompactionRender.render_items(Enum.take(items, 2))
    expected = String.replace_prefix(full, first_two, "...[2 older items elided]...")
    budget_tokens = CompactionRender.approx_tokens(expected)

    assert CompactionRender.render_items(items, budget_tokens: budget_tokens) == expected
  end

  test "non-text content parts are placeholders instead of raw payloads" do
    rendered =
      CompactionRender.render_items([
        %{
          "type" => "message",
          "role" => "user",
          "content" => [
            %{
              "type" => "input_image",
              "image_url" => "data:image/png;base64,SECRET_DATA_URL"
            }
          ]
        },
        %{
          "provider_file_id" => "SECRET_FILE_ID"
        },
        %{
          "type" => "input_file",
          "file_data" => "SECRET_FILE_DATA"
        }
      ])

    assert rendered =~ "[input_image omitted]"
    assert rendered =~ "[item omitted]"
    assert rendered =~ "[input_file omitted]"
    refute rendered =~ "SECRET_DATA_URL"
    refute rendered =~ "SECRET_FILE_ID"
    refute rendered =~ "SECRET_FILE_DATA"
  end
end
