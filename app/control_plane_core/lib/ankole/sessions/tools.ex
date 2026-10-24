defmodule Ankole.Sessions.Tools do
  @moduledoc "Dispatches declared calls. Durable effects and receipts share one transaction."

  alias Ankole.Sessions.PendingCall
  alias Ankole.Sessions.Receipt
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
      Receipts.execute(run, Run.response_id(run.model_response), Run.call_id(call), fn ->
        owner.prepare_in_tx(run, call, args)
      end)
    else
      owner.execute(run, call, args)
    end
    |> case do
      {:ok, %Receipt{result: result, inserted_at: inserted_at}} ->
        ToolResult.decode(result, inserted_at)

      {:ok, result} ->
        result

      {:error, reason} = error when reason in [:stale_driver, :run_closed] ->
        error

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

  # Ash error classes: an invalid input gives its validation details; a
  # framework or unknown error goes to the server log only.
  defp error_message(%Ash.Changeset{} = changeset),
    do: changeset |> Ankole.Ash.validation_details() |> Ankole.JSON.encode!()

  defp error_message(%{class: :invalid} = error) when is_exception(error),
    do: error |> Ankole.Ash.validation_details() |> Ankole.JSON.encode!()

  defp error_message(%{class: class} = error)
       when is_exception(error) and class in [:framework, :unknown] do
    Ankole.Logging.warning(
      "sessions.tools.unexpected_action_error",
      "tool action failed",
      Ankole.Logging.failure_fields(:error, error, [])
    )

    "the operation failed; check the server log"
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

  def observe_pending(run, pending) do
    steered? =
      Enum.any?(Ankole.Sessions.Queue.due(run), fn event ->
        Ankole.Signals.Signal.produced_by_kernel?(event) and event.id in run.pending_event_ids and
          (event.type in ["command.steer", "conversation.message.addressed"] or
             (String.starts_with?(event.type, "im.message.") and
                event.type != "im.message.may_intervene"))
      end)

    Enum.map(PendingCall.waits(pending), fn {id, wait} ->
      {id, observe(run, wait, steered?)}
    end)
  end

  def observe(run, %Wait{} = wait, steered? \\ false) do
    expired? =
      DateTime.diff(DateTime.utc_now(:microsecond), wait.started_at, :millisecond) >=
        wait.timeout_ms

    wait_owner(wait).observe(run, wait, steered?, expired?)
  end

  defp wait_owner(%Wait{kind: :job}), do: Ankole.Sessions.Tools.Jobs
  defp wait_owner(%Wait{kind: :outbox}), do: Ankole.Sessions.Tools.Message

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
