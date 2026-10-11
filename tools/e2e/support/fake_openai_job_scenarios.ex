defmodule Ankole.E2E.FakeOpenAIJobScenarios do
  @moduledoc "Model replies for a real Codex Job that waits across Worker replacement."

  def classify(request, prompt) do
    native? = "exec" in tool_names(request)

    cond do
      native? and String.contains?(prompt, "CHAOS_JOB_FINISH") -> :job_finish
      native? and String.contains?(prompt, "CHAOS_JOB_WORK_RECONNECT") -> :job_reconnect
      native? and String.contains?(prompt, "CHAOS_JOB_WORK") -> :job_work
      String.contains?(prompt, "CHAOS_JOB_REPLY") -> :job_reply
      String.contains?(prompt, "CHAOS_JOB_CREATE") -> :job_create
      String.contains?(prompt, "CHAOS_JOB_WORK") -> :job_notice
      true -> nil
    end
  end

  def action_for(:job_create, 1, request) do
    prompt = Ankole.JSON.encode!(request)

    task =
      if String.contains?(prompt, "CHAOS_JOB_CREATE_RECONNECT"),
        do: "CHAOS_JOB_WORK_RECONNECT Write a file, wait, then finish after reconnection.",
        else:
          "CHAOS_JOB_WORK Write JOB_FILE_BEFORE to state.txt. Ask the parent for the next step."

    task = if String.contains?(prompt, "B02_B03_ONCE"), do: task <> " B02_B03_ONCE", else: task

    call("create", "create_background_job", %{
      "title" => "Worker replacement recovery",
      "task" => task
    })
  end

  def action_for(:job_reply, 1, request) do
    [_, id] = Regex.run(~r/CHAOS_JOB_REPLY (\d+)/, Ankole.JSON.encode!(request))

    call("reply", "send_message_to_background_job", %{
      "job_id" => String.to_integer(id),
      "message" => "CHAOS_JOB_FINISH Read state.txt and append JOB_FILE_AFTER. Then finish.",
      "wait_reply" => false
    })
  end

  # The native Codex exec tool reaches this Chat Completions upstream through
  # kernel's custom_tool_emulation.rs: its code is the function's input field.
  def action_for(:job_work, 1, _request) do
    exec("write", "printf JOB_FILE_BEFORE > state.txt; cat state.txt")
  end

  def action_for(:job_work, 2, _request) do
    call("ask", "request_parent_input", %{
      "questions" => [
        %{
          "id" => "next",
          "header" => "Next step",
          "question" => "The file is ready. What should I do next?"
        }
      ]
    })
  end

  def action_for(:job_reconnect, 1, request) do
    effect =
      if String.contains?(Ankole.JSON.encode!(request), "B02_B03_ONCE"),
        do: "printf x >> effect-count; ",
        else: ""

    exec(
      "slow_write",
      effect <>
        "echo $$ > old-command.pid; printf JOB_FILE_BEFORE > state.txt; while [ ! -f allow-write ]; do sleep 0.1; done; printf JOB_FILE_AFTER >> state.txt; touch late-write.txt; cat state.txt"
    )
  end

  def action_for(:job_reconnect, 2, _request) do
    exec("resume_read", "cat state.txt")
  end

  def action_for(:job_reconnect, _count, _request),
    do: {:completion, "CHAOS_JOB_RECONNECTED", []}

  def action_for(:job_finish, 1, _request) do
    exec("read", "cat state.txt; printf JOB_FILE_AFTER >> state.txt; cat state.txt")
  end

  def action_for(:job_finish, _count, _request),
    do: {:completion, "CHAOS_JOB_FINISHED", []}

  def action_for(kind, _count, _request) when kind in [:job_create, :job_reply, :job_notice],
    do: {:completion, "CHAOS_JOB_ACKNOWLEDGED", []}

  defp exec(id, command) do
    code =
      "const result = await tools.exec_command({cmd: #{Ankole.JSON.encode!(command)}, yield_time_ms: 30000}); text(result.output);"

    call(id, "exec", %{"input" => code})
  end

  defp call(id, name, arguments),
    do: {:tool_call, %{id: "call_job_#{id}", name: name, arguments: arguments}}

  defp tool_names(request),
    do: Enum.map(request["tools"] || [], &get_in(&1, ["function", "name"]))
end
