defmodule Ankole.Sessions.ToolRound do
  @moduledoc "Schedules a round's calls and restores committed tool results."

  alias Ankole.Sessions.Machine
  alias Ankole.Sessions.PendingCall
  alias Ankole.Sessions.Presentation
  alias Ankole.Sessions.Run
  alias Ankole.Sessions.ToolArguments
  alias Ankole.Sessions.ToolCatalog
  alias Ankole.Sessions.ToolResult
  alias Ankole.Sessions.Tools

  alias Ankole.Observability

  def finish_spans(%{run: nil} = data, _opts), do: data

  def finish_spans(%{run: run, pending: pending} = data, opts) do
    Enum.each(pending, fn {_id, entry} ->
      Observability.finish_tool(entry.span, %{
        "is_error" => true,
        "failure_kind" => Keyword.get(opts, :error_type, "turn_ended")
      })
    end)

    Observability.finish_turn(run.span, opts)

    %{
      data
      | run: %{run | span: nil},
        pending: Map.new(pending, fn {id, entry} -> {id, %{entry | span: nil}} end)
    }
  end

  def restore(run) do
    pending =
      PendingCall.new_round(run.calls, run.recovered?)
      |> Map.new(fn {id, entry} ->
        if Map.has_key?(run.receipts, id) do
          tool = ToolCatalog.find(run, entry.call)

          args =
            case ToolArguments.parse(entry.call["arguments"] || "{}") do
              {:ok, args, _repair} -> args
              {:error, _reason} -> %{}
            end

          {id,
           %{
             entry
             | status: :running,
               tool: tool,
               args: args,
               span: Observability.start_tool(run.span, entry.call),
               sequential?: is_nil(tool) or tool.execution_mode == "sequential"
           }}
        else
          {id, entry}
        end
      end)

    {run, pending, events} =
      Enum.reduce(run.calls, {run, pending, []}, fn call, {run, pending, events} ->
        id = Run.call_id(call)

        {run, pending, observed} =
          case Map.fetch(run.receipts, id) do
            {:ok, {:await, wait}} ->
              {pending, observed} = await(run, pending, id, wait)
              {run, pending, observed}

            {:ok, result} ->
              accept(run, pending, id, result)

            :error ->
              {run, pending, []}
          end

        {run, pending, events ++ observed}
      end)

    {%{run | receipts: %{}}, pending, events}
  end

  def next(run, pending) do
    case PendingCall.next(pending, run.calls) do
      {:ok, call, active} ->
        case Tools.prepare(run, call) do
          {:error, result} -> {:result, Run.call_id(call), result}
          {:ok, tool, args} -> prepare(run, pending, call, tool, args, active)
        end

      :none ->
        :none
    end
  end

  defp prepare(run, pending, call, tool, args, active) do
    sequential? = tool.execution_mode == "sequential"

    if PendingCall.blocked?(pending, sequential?, active) do
      :none
    else
      id = Run.call_id(call)

      pending =
        PendingCall.start(
          pending,
          id,
          call,
          tool,
          args,
          pending[id].span || Observability.start_tool(run.span, call),
          sequential?
        )

      events =
        if tool.executor != :worker,
          do: Presentation.tool_activity(call, tool, args, "running"),
          else: []

      {:execute, pending[id], pending, events}
    end
  end

  def await(_run, pending, id, wait) do
    {PendingCall.await(pending, id, wait), Presentation.waiting(pending[id].call, wait)}
  end

  def accept(run, pending, id, result) do
    case pending[id] do
      nil ->
        {run, pending, []}

      entry ->
        Observability.finish_tool(entry.span, ToolResult.encode(result))

        events =
          if entry.tool && entry.tool.executor != :worker do
            phase = if result.is_error == true, do: "failed", else: "completed"
            Presentation.tool_activity(entry.call, entry.tool, entry.args, phase, result)
          else
            []
          end

        events = events ++ (result.presentation || [])

        {run, result} = Tools.attach(run, result)
        run = Machine.failure(run, entry.call, result)

        run = %{
          run
          | results: Map.put(run.results, id, result),
            visible_delivery?:
              run.visible_delivery? or Run.visible_delivery?(run, entry.call, result)
        }

        pending = Map.delete(pending, id)

        if ToolResult.ends_turn?(result) do
          Enum.reduce(PendingCall.queued(pending), {run, pending, events}, fn next_id,
                                                                              {run, pending,
                                                                               events} ->
            {run, pending, observed} =
              accept(run, pending, next_id, Tools.error("An earlier tool ended this turn."))

            {run, pending, events ++ observed}
          end)
        else
          {run, pending, events}
        end
    end
  end

  def observe(run, pending) do
    steered? =
      Enum.any?(Ankole.Sessions.Queue.due(run), fn event ->
        Ankole.Signals.Signal.produced_by_kernel?(event) and event.id in run.pending_event_ids and
          (event.type in ["command.steer", "conversation.message.addressed"] or
             (String.starts_with?(event.type, "im.message.") and
                event.type != "im.message.may_intervene"))
      end)

    Enum.map(PendingCall.waits(pending), fn {id, wait} ->
      {id, Tools.observe(run, wait, steered?)}
    end)
  end
end
