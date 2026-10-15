defmodule Ankole.Sessions.Tools do
  @moduledoc "Dispatches declared calls. Durable effects and receipts share one transaction."

  alias Ankole.Sessions.Receipts
  alias Ankole.Sessions.Run
  alias Ankole.Sessions.Tool
  alias Ankole.Sessions.ToolArguments
  alias Ankole.Sessions.ToolCatalog
  alias Ankole.Sessions.ToolResult
  alias Ankole.Sessions.Wait

  def prepare(run, call) do
    with %{} = tool <- ToolCatalog.find(run, call),
         {:ok, args, _repair} <- arguments(call, tool),
         {:ok, args} <- validate(tool, args) do
      {:ok, tool, args}
    else
      nil ->
        {:error, error("Unknown tool #{call["name"]}", "unknown_tool")}

      {:error, reason} ->
        {:error,
         error("Invalid arguments for tool #{call["name"]}: #{reason}", "invalid_arguments")}
    end
  end

  @doc "Whether a streamed declaration already proves that the call needs a Worker."
  def needs_worker?(run, call) do
    case ToolCatalog.find(run, call) do
      %Tool{executor: :worker} ->
        true

      _tool ->
        false
    end
  end

  def execute(run, call, tool, args) do
    owner = tool.executor

    if Tool.receipt?(tool, args) do
      Receipts.execute(run, Run.response_id(run.model_response), Run.call_id(call), fn repo ->
        owner.execute_in_tx(repo, run, call, args)
      end)
    else
      owner.execute(run, call, args)
    end
    |> case do
      {:ok, %Receipts{result: result, inserted_at: inserted_at}} ->
        ToolResult.decode(result, inserted_at)

      {:ok, result} ->
        result

      {:error, reason} ->
        error(reason)
    end
  end

  def result(details, opts \\ []) do
    struct!(
      ToolResult,
      Keyword.put(opts, :output, Keyword.get(opts, :text, Ankole.JSON.encode!(details)))
      |> Keyword.put(:details, details)
      |> Keyword.delete(:text)
    )
  end

  def error(reason, kind \\ "execution_failed") do
    message = error_message(reason)

    %ToolResult{
      output: "Error: #{message}\nAnalyze the error above and try a different approach.",
      is_error: true,
      failure_kind: kind
    }
  end

  @doc "The result of a call whose execution was interrupted before its outcome was known."
  def interrupted,
    do:
      error(
        "Tool execution was interrupted; its result is unknown. Do not repeat a side effect without checking its authoritative state."
      )

  defp error_message(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, text ->
        String.replace(text, "%{#{key}}", to_string(value))
      end)
    end)
    |> Ankole.JSON.encode!()
  end

  defp error_message(reason) when is_binary(reason), do: reason
  defp error_message(reason), do: inspect(reason, limit: 20, printable_limit: 2_000)

  def attach(run, %ToolResult{} = result) do
    cache =
      Map.merge(run.web_cache, result.web_cache)
      |> Enum.sort_by(fn {_, value} -> value.at end, :desc)
      |> Enum.take(96)
      |> Map.new()

    run = %{run | web_cache: cache, todo: result.todos || run.todo}
    result = %{result | web_cache: %{}}

    case result.cursor do
      {subject, cursor} ->
        pages = run.pages[subject] || %{}

        page =
          if cursor not in [nil, ""],
            do:
              Enum.find_value(pages, fn {p, c} -> if c == cursor, do: p end) ||
                "page_#{map_size(pages) + 1}"

        pages = if page, do: Map.put(pages, page, cursor), else: pages
        details = Map.put(result.details, "next_page", page)

        {%{run | pages: Map.put(run.pages, subject, pages)},
         %{result | cursor: nil, details: details, output: Ankole.JSON.encode!(details)}}

      nil ->
        {run, result}
    end
  end

  def observe(run, %Wait{} = wait, steered? \\ false) do
    expired? =
      DateTime.diff(DateTime.utc_now(:microsecond), wait.started_at, :millisecond) >=
        wait.timeout_ms

    Wait.owner(wait).observe(run, wait, steered?, expired?)
  end

  def cursor(_run, _subject, nil), do: {:ok, nil}

  def cursor(run, subject, page) do
    case get_in(run.pages, [subject, page]) do
      nil -> {:error, "unknown #{subject} page #{page}; use next_page from this turn"}
      cursor -> {:ok, cursor}
    end
  end

  def window(text, offset, total, build, budget \\ 8_000)
      when is_integer(offset) and offset >= 0 do
    cond do
      offset > total or (offset < total and text == "") -> {:error, :invalid_result_offset}
      true -> fit_window(Ankole.Text.utf8_prefix(text, budget), offset, total, build, budget)
    end
  end

  defp fit_window(text, offset, total, build, budget) do
    size = byte_size(text)
    details = build.(text, if(offset + size < total, do: offset + size))

    if byte_size(Ankole.JSON.encode!(details)) <= budget and (size > 0 or offset == total) do
      {:ok, result(details)}
    else
      if size == 0,
        do: {:error, :tool_result_metadata_exceeds_limit},
        else:
          fit_window(
            Ankole.Text.utf8_prefix(text, max(size - 256, 0)),
            offset,
            total,
            build,
            budget
          )
    end
  end

  defp arguments(call, %Tool{schema: %{"type" => "custom"}}),
    do: {:ok, call["input"] || "", :none}

  defp arguments(call, _tool), do: ToolArguments.parse(call["arguments"] || "{}")

  defp validate(%Tool{executor: :worker}, args), do: {:ok, args}

  defp validate(tool, args) do
    args = tool.executor.normalize(tool.name, args)

    ToolArguments.validate(tool.schema["parameters"], args)
  end
end
