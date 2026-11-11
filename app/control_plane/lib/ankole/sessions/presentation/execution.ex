defmodule Ankole.Sessions.Presentation.Execution do
  @moduledoc "Projects a native turn's durable model journal into its visible work history."
  alias Ankole.Sessions.{Presentation, Tools}
  alias Ankole.AIGateway.ResponseItems

  def from_chain(chain, round_states \\ %{}, status \\ "completed", opts \\ []) do
    blocked_toolkits = opts |> Keyword.get(:blocked_toolkits, []) |> MapSet.new()
    blocked_page_ids = opts |> Keyword.get(:blocked_page_ids, []) |> MapSet.new()
    rows = Enum.reverse(chain)

    entries =
      Enum.flat_map(rows, fn row ->
        Enum.map(
          items(row),
          &{&1, (round_states[row.id] || %{results: %{}}).results}
        )
      end)

    keys = ResponseItems.resolved_pair_keys(Enum.map(entries, &elem(&1, 0)))

    entries =
      Enum.zip_with(entries, keys, fn {item, results}, key ->
        {item, results, key || item["id"]}
      end)

    calls =
      entries
      |> Enum.filter(fn {item, _, _} ->
        ResponseItems.call_item?(item) or ResponseItems.budget_role(item) != :none
      end)
      |> Enum.uniq_by(&elem(&1, 2))

    outputs =
      Map.new(
        for {item, results, key} <- entries,
            ResponseItems.output_item?(item),
            do: {key, {item, results[item["call_id"]] || %{}}}
      )

    steps = Enum.map(calls, &step(&1, outputs, status, blocked_toolkits, blocked_page_ids))

    thinking =
      for {%{"type" => "reasoning"} = item, _results, _key} <- entries,
          summary <- item["summary"] || [],
          is_binary(summary["text"]),
          do: summary["text"]

    %{
      "duration_ms" => duration(rows),
      "status" => status,
      "thinking_summary" => Enum.join(thinking, "\n\n"),
      "steps" => steps
    }
    |> Ankole.Attrs.maybe_put(
      "model",
      Enum.find_value(chain, fn row ->
        row.metadata["provider_model"] || row.metadata["request_model"]
      end)
    )
  end

  defp items(%{content: content, metadata: %{"tool_result_journal" => true}}), do: content

  defp items(%{content: content, metadata: metadata}),
    do: Enum.drop(content, metadata["request_item_count"] || 0)

  defp step({call, _results, key}, outputs, status, blocked_toolkits, blocked_page_ids) do
    id = call[ResponseItems.pair_identity_field(call)] || call["id"] || inspect(key)
    {output, result} = Map.get(outputs, key, {%{}, %{}})
    input = call["arguments"] || call["input"] || call["code"] || call["action"]
    output_text = output["output"] || output["result"]
    decoded = decode(output_text)
    args = decode(input)
    name = call["name"] || call["operation"] || call["type"]
    raw_state = step_status(call, output, result, status)

    step_state =
      if (raw_state == "failed" or command_failed_output?(output_text)) and
           (connector_blocked_step?(args, output_text, blocked_toolkits) or
              page_blocked_step?(args, output_text, blocked_page_ids)),
         do: "blocked",
         else: raw_state

    skill_name = skill_name_for_step(name, args, output_text, step_state)

    base =
      %{
        "id" => id,
        "tool" => name,
        "title" => title(name, args, decoded, skill_name),
        "status" => step_state,
        "duration_ms" => result["duration_ms"]
      }
      |> Ankole.Attrs.maybe_put("skill_name", skill_name)
      |> Map.merge(Map.take(result["activity"] || %{}, ["label_key", "label_bindings"]))

    if skill_name do
      base
    else
      Map.merge(base, %{
        "input" => excerpt(sanitize_step_input(name, input, args)),
        "output" => excerpt(visible_output(output_text), 5_000)
      })
    end
  end

  defp visible_output(text) when is_binary(text),
    do: String.replace_suffix(text, Tools.retry_hint(), "")

  defp visible_output(text), do: text

  defp sanitize_step_input("command", input, %{"command" => cmd} = args) when is_binary(cmd) do
    unwrapped = unwrap_shell_command(cmd)

    if unwrapped != cmd do
      Map.put(args, "command", unwrapped)
      |> Ankole.JSON.plain()
      |> Ankole.JSON.encode!()
    else
      input
    end
  end

  defp sanitize_step_input(_name, input, _args), do: input

  defp connector_blocked_step?(args, output_text, blocked_toolkits) do
    MapSet.size(blocked_toolkits) > 0 and
      ((is_binary(output_text) and String.contains?(output_text, "oauth_consent_required")) or
         mcporter_toolkit_blocked?(args, blocked_toolkits))
  end

  defp command_failed_output?("exit_code=0\n" <> _), do: false
  defp command_failed_output?("exit_code=" <> _), do: true

  defp command_failed_output?(text) when is_binary(text),
    do: String.contains?(text, "oauth_consent_required")

  defp command_failed_output?(_), do: false

  defp mcporter_toolkit_blocked?(%{"command" => cmd}, blocked_toolkits) when is_binary(cmd) do
    unwrapped = unwrap_shell_command(cmd)

    String.contains?(unwrapped, "mcporter") and
      Enum.any?(blocked_toolkits, &String.contains?(unwrapped, &1))
  end

  defp mcporter_toolkit_blocked?(_, _), do: false

  defp page_blocked_step?(%{"command" => cmd}, output_text, blocked_page_ids)
       when is_binary(cmd) do
    unwrapped = unwrap_shell_command(cmd)

    MapSet.size(blocked_page_ids) > 0 and
      String.contains?(unwrapped, "ankole-pod") and
      (Enum.any?(blocked_page_ids, &String.contains?(unwrapped, &1)) or
         (is_binary(output_text) and
            (String.contains?(output_text, "\"not_found\"") or
               String.contains?(output_text, "\"forbidden\""))))
  end

  defp page_blocked_step?(_, _, _), do: false

  defp step_status(call, output, result, status) do
    cond do
      result["failure_kind"] == "interrupted" ->
        if status == "failed", do: "failed", else: "stopped"

      result["is_error"] == true or call["status"] == "failed" or
          output["status"] in ["failed", "incomplete"] ->
        "failed"

      map_size(output) > 0 or
          (not ResponseItems.call_item?(call) and call["status"] == "completed") ->
        "completed"

      status == "failed" ->
        "failed"

      true ->
        "stopped"
    end
  end

  defp duration([]), do: 0

  defp duration(rows),
    do: max(DateTime.diff(List.last(rows).updated_at, hd(rows).inserted_at, :millisecond), 0)

  defp title(_name, _args, _result, skill_name) when is_binary(skill_name),
    do: target("Load skill", skill_name)

  defp title("brain.search", args, result, _skill),
    do: target("Search memory", args["query"]) <> count(result, "results", "results")

  defp title(name, args, _result, _skill) when name in ["web_search", "web_search_call"],
    do: target("Search web", args["query"])

  defp title("web_fetch", args, result, _skill) do
    page = List.first(result["results"] || []) || %{}
    target("Read web page", page["title"] || page["url"] || args["url"])
  end

  defp title("command", args, result, _skill) do
    command = unwrap_shell_command(args["command"] || "")

    case Regex.run(~r/^\s*ankole-pod\s+([a-z.]+)(?:\s|$)/, command) do
      [_, operation]
      when operation in [
             "pages.read",
             "pages.list",
             "pages.search",
             "base.tables",
             "base.query",
             "base.schema"
           ] ->
        pod_title(operation, result["result"] || %{})

      _ ->
        target("Run command", command)
    end
  end

  defp title("read_file", args, _result, _skill), do: target("Read file", args["path"])
  defp title("write_file", args, _result, _skill), do: target("Write file", args["path"])
  defp title("edit_file", args, _result, _skill), do: target("Edit file", args["path"])
  defp title("apply_patch", _args, _result, _skill), do: "Apply patch"

  defp title("create_background_job", args, _result, _skill),
    do: target("Create background job", args["title"])

  defp title("respawn_background_job", args, _result, _skill),
    do: target("Continue background job", to_string_or_nil(args["source_job_id"]))

  defp title("send_message_to_background_job", args, _result, _skill),
    do: target("Message background job", to_string_or_nil(args["job_id"]))

  defp title("stop_background_job", args, _result, _skill),
    do: target("Stop background job", to_string_or_nil(args["job_id"]))

  defp title("workflow", args, _result, _skill),
    do: target("Run workflow", args["title"])

  defp title("cancel_workflow", args, _result, _skill),
    do: target("Stop workflow", to_string_or_nil(args["run_id"]))

  defp title("send_to_agent", args, _result, _skill),
    do: target("Ask agent", args["recipient_uid"] || args["agent_uid"])

  defp title(name, _args, _result, _skill), do: name

  @doc false
  def unwrap_shell_command(command) when is_binary(command) do
    trimmed = String.trim(command)

    case Regex.run(~r/^\/?(?:usr\/)?bin\/(?:ba|z)?sh\s+-lc\s+(.+)$/s, trimmed) do
      [_, inner] ->
        unquote_shell_body(String.trim(inner))

      _ ->
        case Regex.run(~r/^(?:ba|z)?sh\s+-lc\s+(.+)$/s, trimmed) do
          [_, inner] -> unquote_shell_body(String.trim(inner))
          _ -> trimmed
        end
    end
  end

  def unwrap_shell_command(_), do: ""

  defp unquote_shell_body(<<"'", rest::binary>>) do
    if String.ends_with?(rest, "'") do
      rest
      |> binary_part(0, byte_size(rest) - 1)
      |> String.replace("'\\''", "'")
      |> String.trim()
    else
      "'" <> rest
    end
  end

  defp unquote_shell_body(<<"\"", rest::binary>>) do
    if String.ends_with?(rest, "\"") do
      rest
      |> binary_part(0, byte_size(rest) - 1)
      |> String.replace("\\\"", "\"")
      |> String.trim()
    else
      "\"" <> rest
    end
  end

  defp unquote_shell_body(value), do: value

  @doc false
  def skill_name_for_step(name, args, output_text, status \\ "completed")

  def skill_name_for_step(_name, _args, output_text, status)
      when status in ["failed", "error"] or is_nil(status) do
    _ = output_text
    nil
  end

  def skill_name_for_step(name, args, output_text, _status) do
    if non_zero_exit_transcript?(output_text) do
      nil
    else
      do_skill_name_for_step(name, args, output_text)
    end
  end

  defp do_skill_name_for_step("skill_view", args, output_text) when is_map(args) do
    non_empty_string(args["name"]) || extract_skill_tag_name(output_text) || "skill"
  end

  defp do_skill_name_for_step("read_file", args, output_text) when is_map(args) do
    skill_name_from_path(args["path"]) || extract_leading_skill_tag_name(output_text)
  end

  defp do_skill_name_for_step("command", args, _output_text) when is_map(args) do
    args["command"]
    |> unwrap_shell_command()
    |> skill_name_from_read_command()
  end

  defp do_skill_name_for_step(_name, _args, _output_text), do: nil

  defp non_zero_exit_transcript?("exit_code=" <> rest) do
    case Integer.parse(rest) do
      {code, _} -> code != 0
      :error -> false
    end
  end

  defp non_zero_exit_transcript?(_), do: false

  defp skill_name_from_path(path) when is_binary(path) do
    case Regex.run(~r/(?:^|\/)([^\/\s'"]+)\/SKILL\.md$/i, String.trim(path)) do
      [_, skill] when skill != "" -> skill
      _ -> nil
    end
  end

  defp skill_name_from_path(_), do: nil

  defp skill_name_from_read_command(command) when is_binary(command) do
    trimmed = String.trim(command)

    if compound_or_redirected_command?(trimmed) do
      nil
    else
      trimmed
      |> parse_single_read_target()
      |> skill_name_from_path()
    end
  end

  defp compound_or_redirected_command?(command) do
    String.contains?(command, ["\n", "\r", "&&", "||", ";", "|", ">", "<", "$(", "`"])
  end

  defp parse_single_read_target(command) do
    cond do
      match =
          Regex.run(~r/^cat(?:\s+-[A-Za-z]+)*\s+(?:'([^']+)'|"([^"]+)"|([^\s'"]+))$/, command) ->
        first_captured_path(match)

      match =
          Regex.run(
            ~r/^(?:head|tail)(?:\s+(?:-[0-9]+|-[nc]\s*[0-9]+))*\s+(?:'([^']+)'|"([^"]+)"|([^\s'"]+))$/,
            command
          ) ->
        first_captured_path(match)

      match =
          Regex.run(
            ~r/^sed\s+-n\s+(?:'[^']+'|"[^"]+"|[^\s'"]+)\s+(?:'([^']+)'|"([^"]+)"|([^\s'"]+))$/,
            command
          ) ->
        first_captured_path(match)

      true ->
        nil
    end
  end

  defp first_captured_path([_whole | groups]),
    do: Enum.find(groups, &(is_binary(&1) and &1 != ""))

  defp extract_leading_skill_tag_name(text) when is_binary(text) do
    if String.starts_with?(String.trim_leading(text), "<skill ") do
      extract_skill_tag_name(text)
    end
  end

  defp extract_leading_skill_tag_name(items) when is_list(items) do
    Enum.find_value(items, fn
      %{"text" => text} when is_binary(text) -> extract_leading_skill_tag_name(text)
      _ -> nil
    end)
  end

  defp extract_leading_skill_tag_name(_), do: nil

  defp extract_skill_tag_name(text) when is_binary(text) do
    case Regex.run(~r/<skill\s+[^>]*name="([^"]+)"/, text) do
      [_, skill] when skill != "" -> skill
      _ -> nil
    end
  end

  defp extract_skill_tag_name(items) when is_list(items) do
    Enum.find_value(items, fn
      %{"text" => text} when is_binary(text) -> extract_skill_tag_name(text)
      _ -> nil
    end)
  end

  defp extract_skill_tag_name(_), do: nil

  defp non_empty_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp non_empty_string(_), do: nil

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value), do: to_string(value)

  defp pod_title("pages.read", result),
    do: target("Read page", get_in(result, ["page", "title"]))

  defp pod_title("pages.list", result),
    do: "List pages" <> count(result, "pages", "pages")

  defp pod_title("pages.search", result),
    do: "Search pages" <> count(result, "results", "pages")

  defp pod_title("base.tables", result),
    do: "List tables" <> count(result, "tables", "tables")

  defp pod_title("base.query", result), do: "Query table" <> count(result, "records", "rows")

  defp pod_title("base.schema", result),
    do: target("Read table schema", get_in(result, ["table", "name"]))

  defp target(operation, detail) when is_binary(detail) and detail != "",
    do: "#{operation}: #{Presentation.activity_excerpt(detail, 120)}"

  defp target(operation, _detail), do: operation

  defp count(result, key, unit) do
    if is_list(result[key]) do
      number = length(result[key])
      unit = if number == 1, do: String.trim_trailing(unit, "s"), else: unit
      " (#{number} #{unit})"
    else
      ""
    end
  end

  defp decode(value) when is_map(value), do: value

  defp decode("exit_code=" <> _ = value) do
    case String.split(value, "\n", parts: 3) do
      [_exit, "duration=" <> _, output] -> decode(output)
      _ -> %{}
    end
  end

  defp decode(value) when is_binary(value) do
    case Ankole.JSON.decode(value) do
      {:ok, %{} = result} -> result
      _ -> %{}
    end
  end

  defp decode(_), do: %{}

  # An excerpt keeps 8,000 characters. Output also keeps its last `tail` characters,
  # because commands report failures and summaries at the end.
  defp excerpt(value, tail \\ 0)
  defp excerpt(nil, _tail), do: ""

  defp excerpt(value, tail) when is_binary(value) do
    cond do
      String.length(value) <= 8_000 -> value
      tail == 0 -> String.slice(value, 0, 8_000) <> "\n…"
      true -> String.slice(value, 0, 8_000 - tail) <> "\n…\n" <> String.slice(value, -tail, tail)
    end
  end

  defp excerpt(value, tail), do: value |> Ankole.JSON.encode!() |> excerpt(tail)
end
