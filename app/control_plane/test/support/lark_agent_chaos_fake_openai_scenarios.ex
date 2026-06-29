defmodule Ankole.LarkAgentChaos.FakeOpenAIScenarios do
  @moduledoc """
  Classifies deterministic fake upstream requests for the Lark Docker worker suite.

  The fake upstream does not replace the worker. It only returns model-visible
  text or OpenAI-compatible tool calls so the real Docker worker can execute the
  same runtime path on every test run.
  """

  alias Ankole.LarkAgentChaos.FakeOpenAISkillScenarios

  @doc """
  Classifies one OpenAI-compatible chat request into a deterministic scenario.
  """
  @spec classify(map()) :: atom()
  def classify(request) do
    # The worker sends full conversation history on tool-loop turns. Matching
    # the whole request first would let an older chaos marker decide a newer
    # turn, so fallback classification uses the last trigger marker in message
    # order instead of "does the whole request contain X?" checks.
    request_text = inspect(request, limit: :infinity, printable_limit: :infinity)
    request_trigger = latest_request_trigger_text(request_text)

    prompt =
      latest_chaos_marker_text(request) ||
        request_trigger ||
        latest_user_text(request) ||
        request_text

    cond do
      is_map(request["response_format"]) and String.contains?(prompt, "CHAOS_AMBIENT_IGNORE") ->
        :ambient_noop_decision

      is_map(request["response_format"]) ->
        :ambient_decision

      String.contains?(prompt, "CHAOS_MALFORMED_STREAM") ->
        :malformed_stream

      String.contains?(prompt, "CHAOS_IDLE_STEER_OK") ->
        :idle_steer

      String.contains?(prompt, "CHAOS_STEERED_OK") ->
        :steered_reply

      String.contains?(prompt, "CHAOS_FOLLOWUP_SECOND_OK") ->
        :followup_second

      String.contains?(prompt, "CHAOS_FOLLOWUP_SLOW") ->
        :followup_slow

      String.contains?(prompt, "CHAOS_FOLLOWUP_RECALL_SLOW") ->
        :followup_recall_slow

      String.contains?(prompt, "CHAOS_DM_ISOLATION_SEED") ->
        :dm_isolation_seed

      String.contains?(prompt, "CHAOS_GROUP_ISOLATION_CHECK") ->
        :group_isolation_check

      String.contains?(prompt, "CHAOS_RECALLED_FOLLOWUP_SHOULD_NOT_RUN") ->
        :recalled_followup

      String.contains?(prompt, "CHAOS_REPLY_ATTACHMENT") ->
        :reply_attachment

      String.contains?(prompt, "CHAOS_TODO_TOOL") ->
        :todo_tool

      String.contains?(prompt, "CHAOS_BROWSER_DOCTOR") ->
        :browser_doctor_tool

      String.contains?(prompt, "CHAOS_BACKGROUND_COMMAND") ->
        :background_command_tool

      String.contains?(prompt, "CHAOS_BACKGROUND_LIFECYCLE") ->
        :background_lifecycle_tool

      String.contains?(prompt, "CHAOS_INTERACTIVE_TERMINAL") ->
        :interactive_terminal_tool

      String.contains?(prompt, "CHAOS_TERMINAL_PERSIST_START") ->
        :terminal_persist_start_tool

      String.contains?(prompt, "CHAOS_TERMINAL_PERSIST_READ") ->
        :terminal_persist_read_tool

      String.contains?(prompt, "CHAOS_BROWSER_OPEN") ->
        :browser_open_tool

      String.contains?(prompt, "CHAOS_BROWSER_RUN") ->
        :browser_run_tool

      String.contains?(prompt, "CHAOS_BROWSER_EXTRACT") ->
        :browser_extract_tool

      String.contains?(prompt, "CHAOS_SKILL_VIEW_ALL") ->
        :skill_view_all_tool

      String.contains?(prompt, "CHAOS_SKILL_VIEW") ->
        :skill_view_tool

      String.contains?(prompt, "CHAOS_SKILL_APPEND") ->
        :skill_append_tool

      String.contains?(prompt, "CHAOS_SKILL_DISABLED") ->
        :skill_disabled_tool

      String.contains?(prompt, "CHAOS_READ_FILE") ->
        :read_file_tool

      String.contains?(prompt, "CHAOS_PATCH_TOOL") ->
        :patch_tool

      String.contains?(prompt, "CHAOS_WORKSPACE_WRITE") ->
        :workspace_write_tool

      String.contains?(prompt, "CHAOS_WORKSPACE_READ") ->
        :workspace_read_tool

      String.contains?(prompt, "CHAOS_AFTER_NEW_RECALL_OK") ->
        :after_new_recall

      String.contains?(prompt, "CHAOS_OLD_RECALL_OK") ->
        :old_recall

      String.contains?(prompt, "CHAOS_NEW_AFTER_OK") ->
        :new_after

      String.contains?(prompt, "CHAOS_SLOW_NEW") ->
        :slow_new_stream

      String.contains?(prompt, "CHAOS_RECALL_SLOW") ->
        :slow_recall_stream

      String.contains?(prompt, "CHAOS_CHECKBACK_WAKE_OK") and
          String.contains?(prompt, "Scheduled checkback wakeup.") ->
        :checkback_wakeup

      String.contains?(prompt, "CHAOS_STEER_TOOL") ->
        :steer_tool

      String.contains?(prompt, "CHAOS_CRON_WAKE_OK") and
          String.contains?(prompt, "Recurring schedule fire.") ->
        :cron_wakeup

      String.contains?(prompt, "CHAOS_SLOW_STOP") ->
        :slow_stop_stream

      String.contains?(prompt, "CHAOS_CHECKBACK_TOOL") or
          request_trigger == "CHAOS_CHECKBACK_TOOL" ->
        :checkback_tool

      String.contains?(prompt, "CHAOS_CRON_TOOL") or request_trigger == "CHAOS_CRON_TOOL" ->
        :cron_tool

      String.contains?(prompt, "CHAOS_AMBIENT_OK") ->
        :ambient_reply

      String.contains?(prompt, "CHAOS_DIRECT_OK") ->
        :direct

      true ->
        :generic
    end
  end

  @doc """
  Returns the fake upstream action for a classified request and repeat count.
  """
  @spec action_for(atom(), pos_integer(), map()) ::
          :rate_limit
          | :malformed_stream
          | :slow_stop_stream
          | {:delayed_completion, String.t(), pos_integer()}
          | {:tool_call, map()}
          | {:completion, String.t(), keyword()}
  def action_for(kind, count, request \\ %{}) do
    cond do
      kind == :direct and count == 1 ->
        :rate_limit

      kind == :malformed_stream ->
        :malformed_stream

      kind in [:slow_stop_stream, :slow_new_stream, :slow_recall_stream] ->
        :slow_stop_stream

      kind in [:followup_slow, :followup_recall_slow] ->
        {:delayed_completion, reply_for(kind), 1_500}

      tool_call = tool_call_for(kind, count, request) ->
        {:tool_call, tool_call}

      kind == :ambient_noop_decision ->
        {:completion, reply_for(kind), [split_text?: false]}

      true ->
        {:completion, reply_for(kind), []}
    end
  end

  defp latest_chaos_marker_text(%{"messages" => messages}) when is_list(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn message ->
      text =
        case message do
          %{"role" => "user", "content" => content} -> content_text(content)
          %{role: "user", content: content} -> content_text(content)
          _other -> nil
        end

      if marker_text?(text), do: text
    end)
  end

  defp latest_chaos_marker_text(_request), do: nil

  defp latest_request_trigger_text(request_text) when is_binary(request_text) do
    [
      {"CHAOS_MALFORMED_STREAM", "CHAOS_MALFORMED_STREAM"},
      {"CHAOS_IDLE_STEER_OK", "CHAOS_IDLE_STEER_OK"},
      {"CHAOS_STEERED_OK", "CHAOS_STEERED_OK"},
      {"CHAOS_FOLLOWUP_SECOND_OK", "CHAOS_FOLLOWUP_SECOND_OK"},
      {"CHAOS_FOLLOWUP_SLOW", "CHAOS_FOLLOWUP_SLOW"},
      {"CHAOS_FOLLOWUP_RECALL_SLOW", "CHAOS_FOLLOWUP_RECALL_SLOW"},
      {"CHAOS_DM_ISOLATION_SEED", "CHAOS_DM_ISOLATION_SEED"},
      {"CHAOS_GROUP_ISOLATION_CHECK", "CHAOS_GROUP_ISOLATION_CHECK"},
      {"CHAOS_RECALLED_FOLLOWUP_SHOULD_NOT_RUN", "CHAOS_RECALLED_FOLLOWUP_SHOULD_NOT_RUN"},
      {"CHAOS_REPLY_ATTACHMENT", "CHAOS_REPLY_ATTACHMENT"},
      {"CHAOS_TODO_TOOL", "CHAOS_TODO_TOOL"},
      {"CHAOS_BROWSER_DOCTOR", "CHAOS_BROWSER_DOCTOR"},
      {"CHAOS_BACKGROUND_COMMAND", "CHAOS_BACKGROUND_COMMAND"},
      {"CHAOS_BACKGROUND_LIFECYCLE", "CHAOS_BACKGROUND_LIFECYCLE"},
      {"CHAOS_INTERACTIVE_TERMINAL", "CHAOS_INTERACTIVE_TERMINAL"},
      {"CHAOS_TERMINAL_PERSIST_START", "CHAOS_TERMINAL_PERSIST_START"},
      {"CHAOS_TERMINAL_PERSIST_READ", "CHAOS_TERMINAL_PERSIST_READ"},
      {"CHAOS_BROWSER_OPEN", "CHAOS_BROWSER_OPEN"},
      {"CHAOS_BROWSER_RUN", "CHAOS_BROWSER_RUN"},
      {"CHAOS_BROWSER_EXTRACT", "CHAOS_BROWSER_EXTRACT"},
      {"CHAOS_SKILL_VIEW_ALL", "CHAOS_SKILL_VIEW_ALL"},
      {"CHAOS_SKILL_VIEW", "CHAOS_SKILL_VIEW"},
      {"CHAOS_SKILL_APPEND", "CHAOS_SKILL_APPEND"},
      {"CHAOS_SKILL_DISABLED", "CHAOS_SKILL_DISABLED"},
      {"CHAOS_READ_FILE", "CHAOS_READ_FILE"},
      {"CHAOS_PATCH_TOOL", "CHAOS_PATCH_TOOL"},
      {"CHAOS_WORKSPACE_WRITE", "CHAOS_WORKSPACE_WRITE"},
      {"CHAOS_WORKSPACE_READ", "CHAOS_WORKSPACE_READ"},
      {"CHAOS_AFTER_NEW_RECALL_OK", "CHAOS_AFTER_NEW_RECALL_OK"},
      {"CHAOS_OLD_RECALL_OK", "CHAOS_OLD_RECALL_OK"},
      {"CHAOS_NEW_AFTER_OK", "CHAOS_NEW_AFTER_OK"},
      {"CHAOS_SLOW_NEW", "CHAOS_SLOW_NEW"},
      {"CHAOS_RECALL_SLOW", "CHAOS_RECALL_SLOW"},
      {"CHAOS_STEER_TOOL", "CHAOS_STEER_TOOL"},
      {"CHAOS_SLOW_STOP", "CHAOS_SLOW_STOP"},
      {"CHAOS_CHECKBACK_TOOL", "CHAOS_CHECKBACK_TOOL"},
      {"lark-chaos-checkback-1", "CHAOS_CHECKBACK_TOOL"},
      {"CHAOS_CRON_TOOL", "CHAOS_CRON_TOOL"},
      {"lark-chaos-cron-1", "CHAOS_CRON_TOOL"},
      {"CHAOS_AMBIENT_IGNORE", "CHAOS_AMBIENT_IGNORE"},
      {"CHAOS_AMBIENT_OK", "CHAOS_AMBIENT_OK"},
      {"CHAOS_DIRECT_OK", "CHAOS_DIRECT_OK"}
    ]
    |> Enum.map(fn {needle, marker} -> {marker, last_index(request_text, needle)} end)
    |> Enum.reject(fn {_marker, index} -> is_nil(index) end)
    |> Enum.max_by(fn {_marker, index} -> index end, fn -> nil end)
    |> case do
      {marker, _index} -> marker
      nil -> nil
    end
  end

  defp last_index(text, marker) do
    text
    |> :binary.matches(marker)
    |> case do
      [] -> nil
      matches -> matches |> Enum.map(fn {index, _length} -> index end) |> Enum.max()
    end
  end

  defp latest_user_text(%{"messages" => messages}) when is_list(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{"role" => "user", "content" => content} -> content_text(content)
      %{role: "user", content: content} -> content_text(content)
      _other -> nil
    end)
  end

  defp latest_user_text(_request), do: nil

  defp content_text(content) when is_binary(content), do: content

  defp content_text(content) when is_list(content) do
    content
    |> Enum.map(&content_text/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp content_text(%{"text" => text}) when is_binary(text), do: text
  defp content_text(%{text: text}) when is_binary(text), do: text
  defp content_text(content) when is_map(content), do: inspect(content)
  defp content_text(_content), do: nil

  defp marker_text?(text) when is_binary(text) do
    Enum.any?(
      [
        "CHAOS_MALFORMED_STREAM",
        "CHAOS_STEERED_OK",
        "CHAOS_IDLE_STEER_OK",
        "CHAOS_FOLLOWUP_SECOND_OK",
        "CHAOS_FOLLOWUP_SLOW",
        "CHAOS_FOLLOWUP_RECALL_SLOW",
        "CHAOS_DM_ISOLATION_SEED",
        "CHAOS_GROUP_ISOLATION_CHECK",
        "CHAOS_RECALLED_FOLLOWUP_SHOULD_NOT_RUN",
        "CHAOS_REPLY_ATTACHMENT",
        "CHAOS_TODO_TOOL",
        "CHAOS_BROWSER_DOCTOR",
        "CHAOS_BACKGROUND_COMMAND",
        "CHAOS_BACKGROUND_LIFECYCLE",
        "CHAOS_INTERACTIVE_TERMINAL",
        "CHAOS_TERMINAL_PERSIST_START",
        "CHAOS_TERMINAL_PERSIST_READ",
        "CHAOS_BROWSER_OPEN",
        "CHAOS_BROWSER_RUN",
        "CHAOS_BROWSER_EXTRACT",
        "CHAOS_SKILL_VIEW_ALL",
        "CHAOS_SKILL_VIEW",
        "CHAOS_SKILL_APPEND",
        "CHAOS_SKILL_DISABLED",
        "CHAOS_READ_FILE",
        "CHAOS_PATCH_TOOL",
        "CHAOS_WORKSPACE_WRITE",
        "CHAOS_WORKSPACE_READ",
        "CHAOS_AFTER_NEW_RECALL_OK",
        "CHAOS_OLD_RECALL_OK",
        "CHAOS_NEW_AFTER_OK",
        "CHAOS_SLOW_NEW",
        "CHAOS_RECALL_SLOW",
        "CHAOS_CHECKBACK_WAKE_OK",
        "CHAOS_STEER_TOOL",
        "CHAOS_CRON_WAKE_OK",
        "CHAOS_SLOW_STOP",
        "CHAOS_CHECKBACK_TOOL",
        "CHAOS_CRON_TOOL",
        "CHAOS_AMBIENT_IGNORE",
        "CHAOS_AMBIENT_OK",
        "CHAOS_DIRECT_OK"
      ],
      &String.contains?(text, &1)
    )
  end

  defp marker_text?(_text), do: false

  defp reply_for(:ambient_decision),
    do: ~s({"intervene":true,"reason":"fake Feishu chaos handoff needs a visible reply"})

  defp reply_for(:ambient_noop_decision),
    do: ~s({"intervene":false,"reason":"fake Feishu chaos says the agent should stay silent"})

  defp reply_for(:after_new_recall), do: "CHAOS_AFTER_NEW_RECALL_OK"
  defp reply_for(:ambient_reply), do: "CHAOS_AMBIENT_OK"
  defp reply_for(:background_command_tool), do: "CHAOS_BACKGROUND_COMMAND_OK"
  defp reply_for(:background_lifecycle_tool), do: "CHAOS_BACKGROUND_LIFECYCLE_OK"
  defp reply_for(:browser_doctor_tool), do: "CHAOS_BROWSER_DOCTOR_OK"
  defp reply_for(:browser_extract_tool), do: "CHAOS_BROWSER_EXTRACT_OK"
  defp reply_for(:browser_open_tool), do: "CHAOS_BROWSER_OPEN_OK"
  defp reply_for(:browser_run_tool), do: "CHAOS_BROWSER_RUN_OK"
  defp reply_for(:checkback_tool), do: "CHAOS_CHECKBACK_OK"
  defp reply_for(:checkback_wakeup), do: "CHAOS_CHECKBACK_WAKE_OK"
  defp reply_for(:cron_tool), do: "CHAOS_CRON_OK"
  defp reply_for(:cron_wakeup), do: "CHAOS_CRON_WAKE_OK"
  defp reply_for(:direct), do: "CHAOS_DIRECT_OK"
  defp reply_for(:dm_isolation_seed), do: "CHAOS_DM_ISOLATION_SEED_OK"
  defp reply_for(:followup_second), do: "CHAOS_FOLLOWUP_SECOND_OK"
  defp reply_for(:followup_recall_slow), do: "CHAOS_FOLLOWUP_RECALL_FIRST_OK"
  defp reply_for(:followup_slow), do: "CHAOS_FOLLOWUP_FIRST_OK"
  defp reply_for(:group_isolation_check), do: "CHAOS_GROUP_ISOLATION_OK"
  defp reply_for(:idle_steer), do: "CHAOS_IDLE_STEER_OK"
  defp reply_for(:interactive_terminal_tool), do: "CHAOS_INTERACTIVE_TERMINAL_OK"
  defp reply_for(:new_after), do: "CHAOS_NEW_AFTER_OK"
  defp reply_for(:old_recall), do: "CHAOS_OLD_RECALL_OK"
  defp reply_for(:patch_tool), do: "CHAOS_PATCH_TOOL_OK"
  defp reply_for(:read_file_tool), do: "CHAOS_READ_FILE_OK"
  defp reply_for(:recalled_followup), do: "CHAOS_RECALLED_FOLLOWUP_SHOULD_NOT_RUN"
  defp reply_for(:reply_attachment), do: "CHAOS_REPLY_ATTACHMENT_OK"
  defp reply_for(:skill_append_tool), do: "CHAOS_SKILL_APPEND_OK"
  defp reply_for(:skill_disabled_tool), do: "CHAOS_SKILL_DISABLED_OK"
  defp reply_for(:skill_view_all_tool), do: "CHAOS_SKILL_VIEW_ALL_OK"
  defp reply_for(:skill_view_tool), do: "CHAOS_SKILL_VIEW_OK"
  defp reply_for(:steered_reply), do: "CHAOS_STEERED_OK"
  defp reply_for(:terminal_persist_read_tool), do: "CHAOS_TERMINAL_PERSIST_READ_OK"
  defp reply_for(:terminal_persist_start_tool), do: "CHAOS_TERMINAL_PERSIST_START_OK"
  defp reply_for(:todo_tool), do: "CHAOS_TODO_OK"
  defp reply_for(:workspace_read_tool), do: "CHAOS_WORKSPACE_READ_OK"
  defp reply_for(:workspace_write_tool), do: "CHAOS_WORKSPACE_WRITE_OK"
  defp reply_for(:generic), do: "CHAOS_GENERIC_OK"

  defp tool_call_for(:reply_attachment, 1), do: tool_call_for(:reply_attachment_command)
  defp tool_call_for(:reply_attachment, 2), do: tool_call_for(:reply_attachment_tool)
  defp tool_call_for(:todo_tool, 1), do: tool_call_for(:todo_tool_start)
  defp tool_call_for(:todo_tool, 2), do: tool_call_for(:todo_tool_complete)
  defp tool_call_for(:browser_doctor_tool, 1), do: tool_call_for(:browser_doctor_tool)
  defp tool_call_for(:background_command_tool, 1), do: tool_call_for(:background_command_tool)

  defp tool_call_for(:interactive_terminal_tool, count) when count in 1..4,
    do: tool_call_for({:interactive_terminal_tool, count})

  defp tool_call_for(:terminal_persist_start_tool, count) when count in 1..2,
    do: tool_call_for({:terminal_persist_start_tool, count})

  defp tool_call_for(:terminal_persist_read_tool, count) when count in 1..3,
    do: tool_call_for({:terminal_persist_read_tool, count})

  defp tool_call_for(:browser_open_tool, 1), do: tool_call_for(:browser_open_tool)
  defp tool_call_for(:browser_run_tool, 1), do: tool_call_for(:browser_run_tool)
  defp tool_call_for(:browser_extract_tool, 1), do: tool_call_for(:browser_extract_tool)

  defp tool_call_for(kind, count)
       when kind in [
              :skill_view_tool,
              :skill_view_all_tool,
              :skill_append_tool,
              :skill_disabled_tool
            ],
       do: FakeOpenAISkillScenarios.tool_call_for(kind, count)

  defp tool_call_for(:read_file_tool, 1), do: tool_call_for(:read_file_command)
  defp tool_call_for(:read_file_tool, 2), do: tool_call_for(:read_file_tool)
  defp tool_call_for(:patch_tool, 1), do: tool_call_for(:patch_command)
  defp tool_call_for(:patch_tool, 2), do: tool_call_for(:patch_tool)
  defp tool_call_for(:patch_tool, 3), do: tool_call_for(:patch_read_file_tool)
  defp tool_call_for(:workspace_write_tool, 1), do: tool_call_for(:workspace_write_command)
  defp tool_call_for(:workspace_read_tool, 1), do: tool_call_for(:workspace_read_file_tool)

  defp tool_call_for(kind, 1) when kind in [:checkback_tool, :cron_tool, :steer_tool],
    do: tool_call_for(kind)

  defp tool_call_for(_kind, _count), do: nil

  defp tool_call_for(:checkback_tool) do
    %{
      id: "call_lark_chaos_checkback",
      name: "check_back_later",
      arguments: %{
        "reason" => "Lark chaos checkback",
        "check" => "Confirm CHAOS_CHECKBACK_WAKE_OK",
        "after" => %{"value" => 5, "unit" => "minute"},
        "idempotency_key" => "lark-chaos-checkback-1"
      }
    }
  end

  defp tool_call_for(:cron_tool) do
    anchor_at =
      DateTime.utc_now()
      |> DateTime.add(10, :minute)
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

    %{
      id: "call_lark_chaos_cron",
      name: "cron",
      arguments: %{
        "action" => "add",
        "name" => "lark-chaos-cron",
        "schedule" => %{"kind" => "every", "every_ms" => 60_000, "anchor_at" => anchor_at},
        "payload" => %{"task" => "CHAOS_CRON_WAKE_OK"},
        "idempotency_key" => "lark-chaos-cron-1"
      }
    }
  end

  defp tool_call_for(:steer_tool) do
    %{
      id: "call_lark_chaos_steer_boundary",
      name: "command",
      arguments: %{
        "command" => "sleep 2; printf 'steer tool boundary ready'",
        "timeout" => 5
      }
    }
  end

  defp tool_call_for(:reply_attachment_command) do
    %{
      id: "call_lark_chaos_reply_attachment_command",
      name: "command",
      arguments: %{
        "command" =>
          "mkdir -p /workspace/user-files/reports && printf 'CHAOS_REPLY_ATTACHMENT_FILE' > /workspace/user-files/reports/chaos-report.txt",
        "timeout" => 5
      }
    }
  end

  defp tool_call_for(:reply_attachment_tool) do
    %{
      id: "call_lark_chaos_reply_attachment",
      name: "reply_attachment",
      arguments: %{
        "path" => "/workspace/user-files/reports/chaos-report.txt",
        "name" => "chaos-report.txt",
        "mimeType" => "text/plain"
      }
    }
  end

  defp tool_call_for(:todo_tool_start) do
    %{
      id: "call_lark_chaos_todo_start",
      name: "todo",
      arguments: %{
        "merge" => false,
        "todos" => [
          %{"id" => "1", "content" => "Inspect the first chaos task", "status" => "in_progress"},
          %{"id" => "2", "content" => "Run the second chaos task", "status" => "pending"},
          %{"id" => "3", "content" => "Report the final chaos result", "status" => "pending"}
        ]
      }
    }
  end

  defp tool_call_for(:todo_tool_complete) do
    %{
      id: "call_lark_chaos_todo_complete",
      name: "todo",
      arguments: %{
        "merge" => true,
        "todos" => [
          %{"id" => "1", "content" => "Inspect the first chaos task", "status" => "completed"},
          %{"id" => "2", "content" => "Run the second chaos task", "status" => "completed"},
          %{"id" => "3", "content" => "Report the final chaos result", "status" => "completed"}
        ]
      }
    }
  end

  defp tool_call_for(:browser_doctor_tool) do
    %{
      id: "call_lark_chaos_browser_doctor",
      name: "browser_doctor",
      arguments: %{"fetch" => false}
    }
  end

  defp tool_call_for(:background_command_tool) do
    %{
      id: "call_lark_chaos_background_command",
      name: "command",
      arguments: %{
        "command" => "sleep 1; printf 'CHAOS_BACKGROUND_COMMAND_DONE'",
        "background" => true,
        "timeout" => 10
      }
    }
  end

  defp tool_call_for(:background_lifecycle_start) do
    %{
      id: "call_lark_chaos_background_lifecycle_start",
      name: "command",
      arguments: %{
        "command" => "sleep 30; printf 'CHAOS_BACKGROUND_LIFECYCLE_DONE'",
        "background" => true,
        "timeout" => 60
      }
    }
  end

  defp tool_call_for({:background_lifecycle_status, background_id}) do
    %{
      id: "call_lark_chaos_background_lifecycle_status",
      name: "command",
      arguments: %{"action" => "status", "backgroundId" => background_id}
    }
  end

  defp tool_call_for({:background_lifecycle_kill, background_id}) do
    %{
      id: "call_lark_chaos_background_lifecycle_kill",
      name: "command",
      arguments: %{"action" => "kill", "backgroundId" => background_id}
    }
  end

  defp tool_call_for({:interactive_terminal_tool, 1}) do
    %{
      id: "call_lark_chaos_terminal_start",
      name: "interactive_terminal",
      arguments: %{
        "action" => "start",
        "session" => "chaos-terminal",
        "command" => "bash",
        "workdir" => "/workspace/user-files"
      }
    }
  end

  defp tool_call_for({:interactive_terminal_tool, 2}) do
    %{
      id: "call_lark_chaos_terminal_send",
      name: "interactive_terminal",
      arguments: %{
        "action" => "send",
        "session" => "chaos-terminal",
        "input" => "pwd; printf 'CHAOS_INTERACTIVE_TERMINAL_SCREEN'",
        "enter" => true
      }
    }
  end

  defp tool_call_for({:interactive_terminal_tool, 3}) do
    %{
      id: "call_lark_chaos_terminal_capture",
      name: "interactive_terminal",
      arguments: %{"action" => "capture", "session" => "chaos-terminal", "lines" => 40}
    }
  end

  defp tool_call_for({:interactive_terminal_tool, 4}) do
    %{
      id: "call_lark_chaos_terminal_kill",
      name: "interactive_terminal",
      arguments: %{"action" => "kill", "session" => "chaos-terminal"}
    }
  end

  defp tool_call_for({:terminal_persist_start_tool, 1}) do
    %{
      id: "call_lark_chaos_terminal_persist_start",
      name: "interactive_terminal",
      arguments: %{
        "action" => "start",
        "session" => "chaos-persist",
        "command" => "bash",
        "workdir" => "/workspace/user-files"
      }
    }
  end

  defp tool_call_for({:terminal_persist_start_tool, 2}) do
    %{
      id: "call_lark_chaos_terminal_persist_seed",
      name: "interactive_terminal",
      arguments: %{
        "action" => "send",
        "session" => "chaos-persist",
        "input" =>
          "mkdir -p persist-demo; cd persist-demo; printf 'CHAOS_TERMINAL_PERSISTED\\n' > note.txt; pwd",
        "enter" => true
      }
    }
  end

  defp tool_call_for({:terminal_persist_read_tool, 1}) do
    %{
      id: "call_lark_chaos_terminal_persist_read",
      name: "interactive_terminal",
      arguments: %{
        "action" => "send",
        "session" => "chaos-persist",
        "input" => "pwd; ls; cat note.txt",
        "enter" => true
      }
    }
  end

  defp tool_call_for({:terminal_persist_read_tool, 2}) do
    %{
      id: "call_lark_chaos_terminal_persist_capture",
      name: "interactive_terminal",
      arguments: %{"action" => "capture", "session" => "chaos-persist", "lines" => 80}
    }
  end

  defp tool_call_for({:terminal_persist_read_tool, 3}) do
    %{
      id: "call_lark_chaos_terminal_persist_kill",
      name: "interactive_terminal",
      arguments: %{"action" => "kill", "session" => "chaos-persist"}
    }
  end

  defp tool_call_for(:browser_open_tool) do
    %{
      id: "call_lark_chaos_browser_open",
      name: "browser_open",
      arguments: %{
        "url" => "https://example.com",
        "taskId" => "lark-chaos-open",
        "timeout" => 30,
        "profileMode" => "ephemeral"
      }
    }
  end

  defp tool_call_for(:browser_run_tool) do
    %{
      id: "call_lark_chaos_browser_run",
      name: "browser_run",
      arguments: %{
        "script" => "print('CHAOS_BROWSER_RUN_SCRIPT_OK')",
        "taskId" => "lark-chaos-run",
        "timeout" => 30,
        "profileMode" => "ephemeral"
      }
    }
  end

  defp tool_call_for(:browser_extract_tool) do
    %{
      id: "call_lark_chaos_browser_extract",
      name: "browser_extract",
      arguments: %{
        "url" => "https://example.com",
        "taskId" => "lark-chaos-extract",
        "format" => "text",
        "timeout" => 30,
        "profileMode" => "ephemeral"
      }
    }
  end

  defp tool_call_for(:read_file_command) do
    %{
      id: "call_lark_chaos_read_file_command",
      name: "command",
      arguments: %{
        "command" =>
          "mkdir -p /workspace/user-files/chaos && printf 'CHAOS_READ_FILE_CONTENT\\n' > /workspace/user-files/chaos/read-file.txt",
        "timeout" => 5
      }
    }
  end

  defp tool_call_for(:read_file_tool) do
    %{
      id: "call_lark_chaos_read_file",
      name: "read_file",
      arguments: %{
        "path" => "/workspace/user-files/chaos/read-file.txt",
        "offset" => 1,
        "limit" => 20
      }
    }
  end

  defp tool_call_for(:patch_command) do
    %{
      id: "call_lark_chaos_patch_command",
      name: "command",
      arguments: %{
        "command" =>
          "mkdir -p /workspace/user-files/chaos && printf 'before\\nCHAOS_PATCH_OLD\\nafter\\n' > /workspace/user-files/chaos/patch.txt",
        "timeout" => 5
      }
    }
  end

  defp tool_call_for(:patch_tool) do
    %{
      id: "call_lark_chaos_patch",
      name: "patch",
      arguments: %{
        "path" => "/workspace/user-files/chaos/patch.txt",
        "old_string" => "CHAOS_PATCH_OLD",
        "new_string" => "CHAOS_PATCH_NEW"
      }
    }
  end

  defp tool_call_for(:patch_read_file_tool) do
    %{
      id: "call_lark_chaos_patch_read_file",
      name: "read_file",
      arguments: %{
        "path" => "/workspace/user-files/chaos/patch.txt",
        "offset" => 1,
        "limit" => 20
      }
    }
  end

  defp tool_call_for(:workspace_write_command) do
    %{
      id: "call_lark_chaos_workspace_write",
      name: "command",
      arguments: %{
        "command" =>
          "mkdir -p /workspace/user-files/chaos && printf 'CHAOS_WORKSPACE_PERSISTED\\n' > /workspace/user-files/chaos/persisted.txt",
        "timeout" => 5
      }
    }
  end

  defp tool_call_for(:workspace_read_file_tool) do
    %{
      id: "call_lark_chaos_workspace_read",
      name: "read_file",
      arguments: %{
        "path" => "/workspace/user-files/chaos/persisted.txt",
        "offset" => 1,
        "limit" => 20
      }
    }
  end

  defp tool_call_for(:background_lifecycle_tool, 1, _request),
    do: tool_call_for(:background_lifecycle_start)

  defp tool_call_for(:background_lifecycle_tool, 2, request) do
    request
    |> background_id_from_request()
    |> case do
      nil -> nil
      background_id -> tool_call_for({:background_lifecycle_status, background_id})
    end
  end

  defp tool_call_for(:background_lifecycle_tool, 3, request) do
    request
    |> background_id_from_request()
    |> case do
      nil -> nil
      background_id -> tool_call_for({:background_lifecycle_kill, background_id})
    end
  end

  defp tool_call_for(kind, count, _request), do: tool_call_for(kind, count)

  defp background_id_from_request(request) do
    request_text = inspect(request, limit: :infinity, printable_limit: :infinity)

    with nil <- regex_capture(~r/background_id=([^\s\\n"]+)/, request_text),
         nil <- regex_capture(~r/"backgroundId"\s*=>\s*"([^"]+)"/, request_text),
         nil <- regex_capture(~r/\\"backgroundId\\"\s*=>\s*\\"([^\\"]+)\\"/, request_text) do
      nil
    end
  end

  defp regex_capture(regex, text) do
    case Regex.run(regex, text) do
      [_match, value] -> value
      _other -> nil
    end
  end
end
