defmodule Ankole.Pod.Chat.JobItemProjection do
  @moduledoc """
  Projects stored Background Agent Job `TurnItem` rows into the Pod execution
  inspector's timeline contract (`Ankole.Pod.Chat.ExecutionDetail`).
  """

  alias Ankole.BackgroundAgentJobs.Schemas.{Turn, TurnItem}
  alias Ankole.Sessions.Presentation.Execution

  @spec project_row(TurnItem.t(), Turn.t(), String.t() | nil) :: map() | nil
  def project_row(
        %TurnItem{item: item, item_key: item_key} = row,
        %Turn{} = turn,
        lead_thread_id
      )
      when is_map(item) do
    base = %{
      id: pod_text(item["id"]) || "#{row.turn_id}:#{row.position}",
      threadID: turn.runtime_thread_id,
      isLead: Turn.lead?(turn, lead_thread_id),
      turnStatus: Atom.to_string(turn.status)
    }

    case do_project_item(item["type"], item, item_key, turn) do
      nil -> nil
      projected -> Map.merge(base, projected)
    end
  end

  def project_row(_row, _turn, _lead_thread_id), do: nil

  defp do_project_item("userMessage", item, item_key, _turn) do
    if is_binary(item_key) and String.starts_with?(item_key, "client:") do
      text =
        item["content"]
        |> List.wrap()
        |> Enum.flat_map(fn
          %{"type" => "text", "text" => value} when is_binary(value) -> [value]
          _ -> []
        end)
        |> Enum.join("\n")
        |> String.trim()

      if text != "", do: %{kind: "steer_message", text: text}
    end
  end

  defp do_project_item("agentMessage", item, _item_key, _turn) do
    case pod_text(item["text"]) do
      nil ->
        nil

      text ->
        phase =
          case pod_text(item["phase"]) do
            "final_answer" -> "final_answer"
            _ -> "commentary"
          end

        %{kind: "message", phase: phase, text: text}
    end
  end

  defp do_project_item("plan", item, _item_key, _turn) do
    case pod_text(item["text"]) do
      nil -> nil
      text -> %{kind: "plan", text: text}
    end
  end

  defp do_project_item("reasoning", item, _item_key, _turn) do
    summary =
      item["summary"]
      |> List.wrap()
      |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
      |> Enum.join("\n\n")

    if summary != "", do: %{kind: "reasoning", text: summary}
  end

  defp do_project_item(review_mode, item, _item_key, _turn)
       when review_mode in ["enteredReviewMode", "exitedReviewMode"] do
    case pod_text(item["review"]) do
      nil -> nil
      text -> %{kind: "message", phase: "commentary", text: text}
    end
  end

  defp do_project_item("commandExecution", item, _item_key, turn) do
    raw_command = item["command"] || ""
    clean_command = Execution.unwrap_shell_command(raw_command)
    output = pod_text(item["aggregatedOutput"])
    status = pod_tool_status(item["status"], item["exitCode"], nil, turn.status)

    case Execution.skill_name_for_step("command", %{"command" => raw_command}, output, status) do
      skill_name when is_binary(skill_name) ->
        %{
          kind: "tool",
          toolKind: "skill",
          tool: "skill_view",
          skillName: skill_name,
          title: skill_name,
          status: status,
          durationMs: integer_or_nil(item["durationMs"])
        }
        |> drop_nil_fields()

      nil ->
        command_detail =
          %{
            command: clean_command,
            cwd: pod_text(item["cwd"]),
            output: output,
            exitCode: integer_or_nil(item["exitCode"])
          }
          |> drop_nil_fields()

        %{
          kind: "tool",
          toolKind: "command",
          tool: "command",
          title: clean_command,
          status: status,
          durationMs: integer_or_nil(item["durationMs"]),
          command: command_detail
        }
        |> drop_nil_fields()
    end
  end

  defp do_project_item("fileChange", item, _item_key, turn) do
    files =
      item["changes"]
      |> List.wrap()
      |> Enum.flat_map(fn
        %{"path" => path} = change when is_binary(path) and path != "" ->
          [
            %{
              path: path,
              kind: normalize_file_change_kind(change["kind"]),
              diff: pod_text(change["diff"])
            }
            |> drop_nil_fields()
          ]

        _ ->
          []
      end)

    title =
      case files do
        [%{path: path}] -> path
        [_ | _] -> "#{length(files)} files"
        [] -> "apply_patch"
      end

    %{
      kind: "tool",
      toolKind: "patch",
      tool: "apply_patch",
      title: title,
      status: pod_tool_status(item["status"], nil, nil, turn.status),
      files: files
    }
  end

  defp do_project_item(
         "dynamicToolCall",
         %{"tool" => "request_user_input"},
         _item_key,
         _turn
       ),
       do: nil

  defp do_project_item("dynamicToolCall", item, _item_key, turn) do
    tool_name = pod_text(item["tool"]) || "tool"
    raw_args = item["arguments"]
    args = decode_args_map(raw_args)
    output = unwrap_content_items(item["contentItems"])
    status = pod_tool_status(item["status"], nil, item["success"], turn.status)

    case Execution.skill_name_for_step(tool_name, args, output, status) do
      skill_name when is_binary(skill_name) ->
        %{
          kind: "tool",
          toolKind: "skill",
          tool: "skill_view",
          skillName: skill_name,
          title: skill_name,
          status: status,
          durationMs: integer_or_nil(item["durationMs"])
        }
        |> drop_nil_fields()

      nil ->
        %{
          kind: "tool",
          toolKind: if(tool_name in ["web_search", "brain.search"], do: "search", else: "tool"),
          tool: tool_name,
          title: dynamic_tool_title(tool_name, args),
          status: status,
          durationMs: integer_or_nil(item["durationMs"]),
          input: format_non_empty_payload(if(map_size(args) > 0, do: args, else: raw_args)),
          output: output
        }
        |> drop_nil_fields()
    end
  end

  defp do_project_item("mcpToolCall", item, _item_key, turn) do
    tool_name =
      [
        pod_text(item["server"]) || pod_text(item["namespace"]),
        pod_text(item["tool"]) || pod_text(item["name"])
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(".")
      |> case do
        "" -> "mcp_tool"
        value -> value
      end

    raw_args = item["arguments"]
    args = decode_args_map(raw_args)

    %{
      kind: "tool",
      toolKind: "tool",
      tool: tool_name,
      title: dynamic_tool_title(tool_name, args),
      status: pod_tool_status(item["status"], nil, if(item["error"], do: false), turn.status),
      durationMs: integer_or_nil(item["durationMs"]),
      input: format_non_empty_payload(if(map_size(args) > 0, do: args, else: raw_args)),
      output: unwrap_content_items(item["result"]),
      error: format_non_empty_payload(item["error"])
    }
    |> drop_nil_fields()
  end

  defp do_project_item("collabAgentToolCall", item, _item_key, turn) do
    action = pod_text(item["tool"]) || "collab"
    receivers = item["receiverThreadIds"] |> List.wrap() |> Enum.filter(&is_binary/1)

    %{
      kind: "tool",
      toolKind: "collab",
      tool: action,
      title: action,
      status: pod_tool_status(item["status"], nil, nil, turn.status),
      collab:
        %{
          action: action,
          prompt: pod_text(item["prompt"]),
          receiverThreadIDs: receivers,
          agentSummary: summarize_collab_states(item["agentsStates"])
        }
        |> drop_nil_fields()
    }
  end

  defp do_project_item("webSearch", item, _item_key, _turn) do
    query = pod_text(item["query"])

    %{
      kind: "tool",
      toolKind: "search",
      tool: "web_search",
      title: query || "web_search",
      status: "completed"
    }
  end

  defp do_project_item("imageView", item, _item_key, _turn) do
    path = pod_text(item["path"])

    %{
      kind: "tool",
      toolKind: "tool",
      tool: "view_image",
      title: path || "view_image",
      status: "completed"
    }
  end

  defp do_project_item("sleep", item, _item_key, _turn) do
    duration = integer_or_nil(item["durationMs"])

    %{
      kind: "tool",
      toolKind: "tool",
      tool: "sleep",
      title: "sleep",
      status: "completed",
      durationMs: duration
    }
    |> drop_nil_fields()
  end

  defp do_project_item("imageGeneration", _item, _item_key, _turn) do
    %{
      kind: "tool",
      toolKind: "tool",
      tool: "image_generation",
      title: "image_generation",
      status: "completed"
    }
  end

  defp do_project_item(_type, _item, _item_key, _turn), do: nil

  defp decode_args_map(args) when is_map(args), do: args

  defp decode_args_map(args) when is_binary(args) do
    case Ankole.JSON.decode(args) do
      {:ok, %{} = map} -> map
      _ -> %{}
    end
  end

  defp decode_args_map(_), do: %{}

  defp pod_tool_status(raw_status, exit_code, success, turn_status) do
    cond do
      raw_status in ["failed", "declined"] ->
        "failed"

      success == false ->
        "failed"

      is_integer(exit_code) and exit_code != 0 and raw_status == "completed" ->
        "failed"

      raw_status == "completed" ->
        "completed"

      raw_status in ["inProgress", "in_progress", "running"] and turn_status == :in_progress ->
        "running"

      raw_status in ["inProgress", "in_progress", "running"] ->
        "stopped"

      turn_status == :failed ->
        "failed"

      turn_status == :interrupted ->
        "stopped"

      true ->
        "completed"
    end
  end

  defp normalize_file_change_kind(%{"type" => type}) when is_binary(type),
    do: normalize_file_change_kind(type)

  defp normalize_file_change_kind("add"), do: "add"
  defp normalize_file_change_kind("create"), do: "add"
  defp normalize_file_change_kind("delete"), do: "delete"
  defp normalize_file_change_kind("remove"), do: "delete"
  defp normalize_file_change_kind(_), do: "update"

  defp unwrap_content_items(nil), do: nil
  defp unwrap_content_items(""), do: nil

  defp unwrap_content_items(value) when is_binary(value) do
    pod_text(value)
  end

  defp unwrap_content_items(items) when is_list(items) do
    texts =
      Enum.flat_map(items, fn
        %{"text" => text} when is_binary(text) and text != "" -> [text]
        text when is_binary(text) and text != "" -> [text]
        _ -> []
      end)

    cond do
      texts != [] ->
        joined = Enum.join(texts, "\n") |> String.trim()
        if joined != "", do: joined

      items == [] ->
        nil

      true ->
        format_non_empty_payload(items)
    end
  end

  defp unwrap_content_items(%{"content" => content}) when is_list(content),
    do: unwrap_content_items(content)

  defp unwrap_content_items(value), do: format_non_empty_payload(value)

  defp format_non_empty_payload(nil), do: nil
  defp format_non_empty_payload(""), do: nil
  defp format_non_empty_payload(map) when map == %{}, do: nil
  defp format_non_empty_payload([]), do: nil

  defp format_non_empty_payload(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed in ["", "{}", "[]", "null"], do: nil, else: value
  end

  defp format_non_empty_payload(value) do
    value |> Ankole.JSON.plain() |> Ankole.JSON.encode!()
  end

  defp dynamic_tool_title(tool_name, args) when is_map(args) do
    detail =
      pod_text(args["title"]) ||
        pod_text(args["path"]) ||
        pod_text(args["query"]) ||
        pod_text(args["url"]) ||
        pod_text(args["name"])

    if detail, do: "#{tool_name}: #{detail}", else: tool_name
  end

  defp summarize_collab_states(states) when is_map(states) and map_size(states) > 0 do
    states
    |> Enum.flat_map(fn {_thread_id, state} ->
      case state do
        %{"message" => msg} when is_binary(msg) and msg != "" -> [String.trim(msg)]
        _ -> []
      end
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> pod_text()
  end

  defp summarize_collab_states(_), do: nil

  defp pod_text(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: value
  end

  defp pod_text(_), do: nil

  defp integer_or_nil(value) when is_integer(value), do: value
  defp integer_or_nil(_), do: nil

  defp drop_nil_fields(map) when is_map(map) do
    Map.reject(map, fn {_k, v} -> is_nil(v) end)
  end
end
