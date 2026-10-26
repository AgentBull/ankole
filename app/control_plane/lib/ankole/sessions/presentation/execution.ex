defmodule Ankole.Sessions.Presentation.Execution do
  @moduledoc "Projects a native turn's durable model journal into its visible work history."
  alias Ankole.Sessions.Presentation
  alias Ankole.AIGateway.ResponseItems

  def from_chain(chain, round_states \\ %{}, status \\ "completed") do
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

    steps = Enum.map(calls, &step(&1, outputs, status))

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

  defp step({call, _results, key}, outputs, status) do
    id = call[ResponseItems.pair_identity_field(call)] || call["id"] || inspect(key)
    {output, result} = Map.get(outputs, key, {%{}, %{}})
    input = call["arguments"] || call["input"] || call["code"] || call["action"]
    output_text = output["output"] || output["result"]
    decoded = decode(output_text)
    args = decode(input)
    name = call["name"] || call["operation"] || call["type"]

    %{
      "id" => id,
      "tool" => name,
      "title" => title(name, args, decoded),
      "status" => step_status(call, output, result, status),
      "duration_ms" => result["duration_ms"],
      "input" => excerpt(input),
      "output" => excerpt(output_text)
    }
  end

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

  defp title("brain.search", args, result),
    do: target("Search memory", args["query"]) <> count(result, "results", "results")

  defp title(name, args, _result) when name in ["web_search", "web_search_call"],
    do: target("Search web", args["query"])

  defp title("web_fetch", _args, result) do
    page = List.first(result["results"] || []) || %{}
    target("Read web page", page["title"] || page["url"])
  end

  defp title("command", args, result) do
    command = args["command"] || ""

    case Regex.run(~r/^\s*ankole-pod\s+([a-z.]+)(?:\s|$)/, command) do
      [_, operation] when operation in ["pages.read", "base.query", "base.schema"] ->
        pod_title(operation, result["result"] || %{})

      _ ->
        target("Run command", command)
    end
  end

  defp title("read_file", args, _result), do: target("Read file", args["path"])
  defp title(name, _args, _result), do: name

  defp pod_title("pages.read", result),
    do: target("Read page", get_in(result, ["page", "title"]))

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

  defp excerpt(nil), do: ""

  defp excerpt(value) when is_binary(value) do
    case String.split_at(value, 8_000) do
      {head, ""} -> head
      {head, _rest} -> head <> "\n…"
    end
  end

  defp excerpt(value), do: value |> Ankole.JSON.encode!() |> excerpt()
end
