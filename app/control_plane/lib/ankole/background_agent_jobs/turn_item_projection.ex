defmodule Ankole.BackgroundAgentJobs.TurnItemProjection do
  @moduledoc """
  Projects one sanitized semantic thread item into `ankole_chatml` messages.

  The Worker ships semantic items as the one turn content stream; every
  trajectory read path derives its messages from the stored items with this
  module. The projection must keep the exact message shapes that
  `Ankole.BackgroundAgentJobs.Trajectory.valid_group_content?/1` accepts and
  that the message-causality readers (`client:` item keys, pending tool
  scans) rely on.
  """

  alias Ankole.Text

  @max_tool_arguments_bytes 64 * 1_024
  @truncation_suffix "...[truncated]"

  @doc """
  Returns `{messages, truncated?}` for one semantic item.

  An empty message list means the item carries no projectable content; the
  item itself stays stored for replay.
  """
  @spec project(map()) :: {[map()], boolean()}
  def project(%{"type" => type} = item) do
    case do_project(type, item) do
      {messages, truncated} -> {messages, truncated}
      messages when is_list(messages) -> {messages, false}
    end
  end

  def project(_item), do: {[], false}

  defp do_project("userMessage", item) do
    message = %{"role" => "user", "content" => user_content(item["content"])}
    [put_present(message, "id", text(item["clientId"]) || text(item["id"]))]
  end

  defp do_project("hookPrompt", item) do
    {content, truncated} = bounded_json_string(item["fragments"])
    {[%{"id" => item["id"], "role" => "developer", "content" => content}], truncated}
  end

  defp do_project("agentMessage", item) do
    [
      %{
        "id" => item["id"],
        "role" => "assistant",
        "content" => string(item["text"]),
        "metadata" => %{"phase" => text(item["phase"]) || "assistant"}
      }
    ]
  end

  defp do_project("plan", item), do: [assistant_phase(item["id"], item["text"], "plan")]

  defp do_project("reasoning", item) do
    summary =
      item["summary"]
      |> List.wrap()
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.join("\n")

    if summary == "",
      do: [],
      else: [assistant_phase(item["id"], summary, "reasoning_summary")]
  end

  defp do_project("commandExecution", item) do
    tool_pair(
      item["id"],
      nil,
      "shell",
      %{"command" => item["command"], "cwd" => item["cwd"]},
      string(item["aggregatedOutput"]),
      %{
        "status" => item["status"],
        "exit_code" => item["exitCode"],
        "duration_ms" => item["durationMs"]
      }
    )
  end

  defp do_project("fileChange", item) do
    tool_pair(item["id"], nil, "apply_patch", %{"changes" => item["changes"]}, "", %{
      "status" => item["status"]
    })
  end

  defp do_project("mcpToolCall", item) do
    {namespace, name} = mcp_tool_identity(item)

    tool_pair(
      item["id"],
      namespace,
      name,
      item["arguments"],
      item["result"] || item["error"] || "",
      %{"status" => item["status"], "duration_ms" => item["durationMs"]}
    )
  end

  defp do_project(
         "dynamicToolCall",
         %{"tool" => "request_user_input", "status" => "inProgress"} = item
       ) do
    {message, truncated} =
      tool_call_message(item["id"], text(item["namespace"]), item["tool"], item["arguments"], %{
        "status" => "pending_user_input"
      })

    {[message], truncated}
  end

  defp do_project("dynamicToolCall", item) do
    tool_pair(
      item["id"],
      text(item["namespace"]),
      text(item["tool"]) || "dynamic_tool",
      item["arguments"],
      item["contentItems"] || "",
      %{
        "status" => item["status"],
        "success" => item["success"],
        "duration_ms" => item["durationMs"],
        "execution_mechanism" => "local_dynamic"
      }
    )
  end

  defp do_project("collabAgentToolCall", item) do
    tool_pair(
      item["id"],
      "collaboration",
      collaboration_replay_tool(string(item["tool"])),
      collab_arguments(item),
      collab_outcome(item),
      %{"status" => item["status"]}
    )
  end

  defp do_project("webSearch", item) do
    tool_pair(
      item["id"],
      nil,
      "web_search",
      %{"query" => item["query"], "action" => item["action"]},
      "",
      %{"status" => "completed", "execution_mechanism" => "provider_hosted"}
    )
  end

  defp do_project("imageView", item) do
    tool_pair(item["id"], nil, "view_image", %{"path" => item["path"]}, "", %{
      "status" => "completed"
    })
  end

  defp do_project("sleep", item) do
    tool_pair(item["id"], nil, "sleep", %{"duration_ms" => item["durationMs"]}, "", %{
      "status" => "completed"
    })
  end

  defp do_project("imageGeneration", item) do
    tool_pair(item["id"], nil, "image_generation", item, "", %{"status" => "completed"})
  end

  defp do_project("enteredReviewMode", item),
    do: [assistant_phase(item["id"], item["review"], "entered_review_mode")]

  defp do_project("exitedReviewMode", item),
    do: [assistant_phase(item["id"], item["review"], "exited_review_mode")]

  defp do_project("contextCompaction", item) do
    tool_pair(item["id"], nil, "context_compaction", %{}, "", %{"status" => "completed"})
  end

  defp do_project(_type, _item), do: []

  defp assistant_phase(id, content, phase) do
    %{
      "id" => id,
      "role" => "assistant",
      "content" => string(content),
      "metadata" => %{"phase" => phase}
    }
  end

  defp tool_pair(id, namespace, name, arguments, result, metadata) do
    {call, call_truncated} = tool_call_message(id, namespace, name, arguments, nil)

    {content, result_truncated} =
      if is_binary(result), do: {result, false}, else: bounded_json_string(result)

    result_message =
      %{
        "id" => "#{id}:result",
        "role" => "tool",
        "tool_call_id" => id,
        "name" => name,
        "content" => content,
        "metadata" => metadata
      }
      |> put_present("namespace", namespace)

    {[call, result_message], call_truncated or result_truncated}
  end

  defp tool_call_message(id, namespace, name, arguments, metadata) do
    {encoded_arguments, truncated} = bounded_json_string(arguments || %{})

    message =
      %{
        "id" => "#{id}:call",
        "role" => "assistant",
        "content" => "",
        "tool_calls" => [
          %{
            "id" => id,
            "type" => "function",
            "function" =>
              %{"name" => name, "arguments" => encoded_arguments}
              |> put_present("namespace", namespace)
          }
        ]
      }

    message = if metadata, do: Map.put(message, "metadata", metadata), else: message
    {message, truncated}
  end

  defp mcp_tool_identity(item) do
    server = text(item["server"])
    tool = text(item["tool"])

    namespace = text(item["namespace"]) || if(server, do: mcp_namespace(server))
    name = text(item["name"]) || responses_identifier(tool || "mcp_tool")
    {namespace, name}
  end

  defp mcp_namespace("mcp__" <> _rest = server), do: server
  defp mcp_namespace(server), do: "mcp__#{responses_identifier(server)}"

  defp responses_identifier(value), do: String.replace(value, ~r/[^A-Za-z0-9_]/, "_")

  defp collaboration_replay_tool("spawnAgent"), do: "spawn_agent"
  defp collaboration_replay_tool("sendInput"), do: "send_message"
  defp collaboration_replay_tool("resumeAgent"), do: "followup_task"
  defp collaboration_replay_tool("wait"), do: "wait_agent"
  defp collaboration_replay_tool("closeAgent"), do: "interrupt_agent"
  defp collaboration_replay_tool(tool), do: tool

  defp collab_arguments(%{"tool" => "spawnAgent"} = item) do
    %{}
    |> put_present("prompt", item["prompt"])
    |> put_present("model", item["model"])
    |> put_present("reasoning_effort", item["reasoningEffort"])
  end

  defp collab_arguments(%{"tool" => "sendInput"} = item) do
    %{"receiver_thread_ids" => item["receiverThreadIds"]}
    |> put_present("input", item["prompt"])
  end

  defp collab_arguments(item), do: %{"receiver_thread_ids" => item["receiverThreadIds"]}

  defp collab_outcome(item) do
    states = if is_map(item["agentsStates"]), do: item["agentsStates"], else: %{}

    thread_ids =
      (List.wrap(item["receiverThreadIds"]) ++ Map.keys(states))
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    %{
      "status" => item["status"],
      "agents" =>
        Enum.map(thread_ids, fn thread_id ->
          agent = states[thread_id]

          %{"thread_id" => thread_id}
          |> put_present("status", agent && agent["status"])
          |> put_present("message", agent && agent["message"])
        end)
    }
  end

  defp user_content(content) do
    parts = content |> List.wrap() |> Enum.filter(&is_map/1)

    if Enum.all?(parts, &(&1["type"] == "text")) do
      Enum.map_join(parts, "", &string(&1["text"]))
    else
      parts
    end
  end

  defp bounded_json_string(value) do
    serialized = Ankole.JSON.encode!(value)

    if byte_size(serialized) <= @max_tool_arguments_bytes do
      {serialized, false}
    else
      preview_bytes = div(@max_tool_arguments_bytes - 1_024, 2)
      preview = Text.truncate_utf8_window(serialized, preview_bytes, @truncation_suffix)
      {Ankole.JSON.encode!(%{"truncated" => true, "preview" => preview}), true}
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp text(value) when is_binary(value) and value != "", do: value
  defp text(_value), do: nil

  defp string(value) when is_binary(value), do: value
  defp string(_value), do: ""
end
