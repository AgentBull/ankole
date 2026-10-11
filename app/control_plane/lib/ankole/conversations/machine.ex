defmodule Ankole.Conversations.Machine do
  @moduledoc "Decides the next step from the recorded model round and tool results."

  alias Ankole.Conversations.{Run, ToolCatalog, ToolResult, Tools}
  alias Ankole.SignalsGateway.AIReplyText
  alias Ankole.Conversations.Scheduled

  @synthesis "You've reached the maximum number of tool-calling iterations allowed. Please provide a final response summarizing what you've found and accomplished so far, without calling any more tools."
  @nudge "You just executed tool calls but returned an empty response. Please process the tool results above and continue with the task."
  @truncated "Your last response reached the output token limit before its tool calls were complete, so none of them ran. Call the tools again with complete arguments, and split large content into smaller calls."
  @workflow_repair "You did not end this Workflow task turn. Call submit_result with the final result, or call sleep when you wait for a delegated job or a later condition. Do not call another tool and do not return prose."
  @visible_repair "You ended your turn with no visible output. This turn was started by an event that requires one, and this turn cannot complete without it: nothing you did reaches the user unless the turn ends with final reply text, a clarify question, or a reply_attachment delivery.\nEnd the turn now with a short final reply. If you already delivered the result through reply_attachment or a generated image, reply with one short closing line. If you are blocked, state plainly what blocked you and what you need."
  @volatile ~w(idempotency_key nonce request_id timestamp tool_call_id uuid)

  def next(run) do
    had_tools = run.round_calls != []
    text = text(run)
    stopped = terminating_result(run)

    max_iterations =
      get_in(run.spec.request_context, ["ai_agent", "max_iterations"]) ||
        Ankole.SignalsGateway.ActorRuntime.AgentConfig.default_max_iterations()

    cond do
      Run.truncated?(run.model_response) ->
        truncated_calls(run)

      stopped ->
        {:finalize, %{run | outcome: stopped.outcome || run.outcome}}

      run.outcome == "iteration_exhausted" and run.iteration > max_iterations ->
        finish(run)

      synthesis_due?(run, max_iterations) ->
        {:request,
         %{
           run
           | outcome: "iteration_exhausted",
             tools: [],
             hosted_tools: [],
             input: [user("#{@synthesis}\nmax_model_iterations=#{max_iterations}") | run.input]
         }}

      had_tools ->
        {:request, %{run | nudged: false}}

      needs_tool_nudge?(run, text) ->
        {:request, %{run | nudged: true, input: [user(@nudge) | run.input]}}

      not run.repaired and stopped_normally?(run) and repair(run, text) != nil ->
        {:request, repaired(run, repair(run, text))}

      run.input != [] ->
        {:request, run}

      run.kind == :workflow_task ->
        finish(run)

      true ->
        {:finalize, %{run | outcome: final_outcome(run, text)}}
    end
  end

  # A Workflow task's input stays open until its call has a result, so every
  # other end of the task reports a failure to the Workflow.
  defp finish(%{kind: :workflow_task} = run) do
    code = run.repair_failure || workflow_failure(text(run))

    {:workflow_failure, run,
     %{
       "ok" => false,
       "code" => code,
       "summary" => "The Workflow task ended without submit_result or sleep.",
       "retryable" => code == "empty_output"
     }}
  end

  defp finish(run), do: {:finalize, run}

  defp synthesis_due?(run, max_iterations),
    do:
      run.round_calls != [] and run.iteration >= max_iterations and
        run.outcome != "iteration_exhausted"

  # A cut-off call is not executable, and AIGateway leaves it out of the replayed
  # history, so the note tells the model what happened to it.
  defp truncated_calls(run) do
    rounds = run.truncated_rounds + 1
    run = %{run | truncated_rounds: rounds}

    if rounds >= 2,
      do: finish(run),
      else:
        {:request,
         %{
           run
           | input:
               Enum.map(
                 run.round_calls,
                 &Run.output(&1, Tools.error("Not run: the response was cut off."))
               ) ++ [user(@truncated) | run.input]
         }}
  end

  defp needs_tool_nudge?(run, text) do
    run.kind not in [:scheduled, :workflow_task] and run.saw_tool_results and not run.nudged and
      stopped_normally?(run) and String.trim(text) == ""
  end

  def text(%{model_response: nil}), do: ""
  def text(run), do: AIReplyText.visible_text(Run.response_output(run.model_response)) || ""

  def user(text),
    do: %{"role" => "user", "content" => [%{"type" => "input_text", "text" => text}]}

  def failure(run, call, result) do
    if result.is_error do
      args = call["arguments"] || call["input"]

      args =
        case Ankole.JSON.decode(args || "") do
          {:ok, v} -> v
          _ -> args
        end

      key =
        {ToolCatalog.namespace(call["namespace"]), call["name"], result.failure_kind, scrub(args)}

      count =
        case run.repeated_failure do
          {^key, n} -> n + 1
          _ -> 1
        end

      run = %{run | repeated_failure: {key, count}}

      if count == 2,
        do: %{run | follow_ups: run.follow_ups ++ [user(warning(call["name"], count))]},
        else: run
    else
      %{run | repeated_failure: nil}
    end
  end

  defp terminating_result(run) do
    Enum.find_value(run.round_calls, fn call ->
      result = run.results[Run.call_id(call)]
      if result && ToolResult.ends_turn?(result), do: result
    end)
  end

  defp stopped_normally?(run), do: run.model_response.metadata["stop_reason"] in [nil, "stop"]
  defp repair(%{kind: :workflow_task}, _text), do: @workflow_repair

  defp repair(%{kind: :scheduled} = run, text) do
    case Scheduled.reply_result(run.event, text) do
      {:ok, _} ->
        nil

      _ ->
        Scheduled.reminder(run.event)
    end
  end

  defp repair(run, text) do
    if String.trim(text) == "" and not run.visible_delivery?, do: @visible_repair
  end

  defp repaired(run, prompt) do
    run = %{run | repaired: true, input: [user(prompt) | run.input]}

    case run.kind do
      :scheduled ->
        %{run | tools: [], hosted_tools: []}

      :workflow_task ->
        %{
          run
          | tools: Enum.filter(run.tools, &(&1.name in ["submit_result", "sleep"])),
            repair_failure: workflow_failure(text(run)),
            hosted_tools: []
        }

      _ ->
        run
    end
  end

  defp workflow_failure(text),
    do: if(String.trim(text) == "", do: "empty_output", else: "schema_noncompliance")

  defp final_outcome(%{kind: :scheduled} = run, text) do
    if Scheduled.reply_result(run.event, text) == {:ok, :silent},
      do: "silent",
      else: run.outcome
  end

  defp final_outcome(run, _text), do: run.outcome

  defp scrub(value) when is_map(value),
    do: value |> Map.drop(@volatile) |> Map.new(fn {k, v} -> {k, scrub(v)} end)

  defp scrub(value) when is_list(value), do: Enum.map(value, &scrub/1)
  defp scrub(value), do: value

  defp warning(tool, count) do
    common =
      "#{tool} has failed #{count} times this turn. This looks like a loop. Do not switch to text-only replies; keep using tools, but diagnose before retrying. First inspect the latest error/output and verify your assumptions. "

    recovery =
      if tool == "command",
        do:
          "For terminal failures, run a small diagnostic such as `pwd && ls -la` in the same tool, then try an absolute path, a simpler command, a different working directory, or a different tool such as read_file/apply_patch.",
        else:
          "Try different arguments, a narrower query/path, an absolute path when relevant, or a different tool that can make progress. If the blocker is external, report the blocker after one diagnostic attempt instead of repeating the same failing path."

    "[Tool loop warning: repeated_tool_failure; count=#{count}; #{common}#{recovery}]"
  end
end
