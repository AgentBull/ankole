defmodule Ankole.Sessions.Tools.Jobs do
  @behaviour Ankole.Sessions.Tool
  @moduledoc false
  @declarations Ankole.JSON.decode!(~S"""
                [
                {
                  "type": "function",
                  "name": "create_background_job",
                  "run_kinds": ["main", "ambient", "scheduled", "workflow_task"],
                  "activity": "background_job_create",
                  "description": "Delegate a durable job to a background agent. title is only a management label and is not sent to Codex. task is the work handed off to the background agent to complete. State in task what the finished deliverable is and what it must satisfy; the background agent verifies against that before finishing. The background agent cannot create background jobs or load a Skill that has runtime=\"main\". Create each job that the work needs with this tool. Do the steps of a runtime=\"main\" Skill yourself, and give a job only the task that the Skill defines.",
                  "parameters": {
                    "type": "object",
                    "properties": {
                      "title": {
                        "type": "string",
                        "minLength": 1,
                        "maxLength": 200
                      },
                      "task": {
                        "type": "string",
                        "minLength": 1
                      },
                      "workspace_template_id": {
                        "type": "string"
                      }
                    },
                    "required": [
                      "title",
                      "task"
                    ],
                    "additionalProperties": false
                  },
                  "execution_mode": "sequential",
                  "read_only": false,
                  "destructive": false
                },
                {
                  "type": "function",
                  "name": "list_background_jobs",
                  "activity": "background_job_list",
                  "description": "List background agent jobs owned by the current Agent. status defaults to live. live includes queued, running, and waiting_on_user. stop includes succeeded, failed, and stopped. Each page contains at most 32 background agent jobs, with the most recently updated background agent job first. Use next_page to continue.",
                  "parameters": {
                    "type": "object",
                    "properties": {
                      "status": {
                        "type": "string",
                        "enum": [
                          "live",
                          "stop"
                        ],
                        "description": "Background agent job group. live includes queued, running, and waiting_on_user. stop includes succeeded, failed, or stopped jobs."
                      },
                      "page": {
                        "type": "string",
                        "pattern": "^page_[1-9]\\d*$",
                        "description": "Turn-local page reference returned by the preceding call."
                      }
                    },
                    "additionalProperties": false
                  },
                  "execution_mode": "parallel",
                  "read_only": true,
                  "destructive": false
                },
                {
                  "type": "function",
                  "name": "show_background_job_details",
                  "run_kinds": ["main", "ambient", "scheduled", "workflow_task"],
                  "activity": "background_job_show",
                  "description": "Show job status, progress, tool execution mechanisms, usage, attempt history, and the latest trajectory page. For an exact persisted result from a succeeded job, set result_offset to 0, concatenate result.output_text, and pass result.next_offset to the next call until it is null. Each result chunk also carries the real Job Workspace (project_path, owned by workspace_owner_job_id) and absolute artifact paths; use those paths to read or copy the files instead of guessing a directory from the job id or a relative path in the text. Result offsets are stable and can be resumed in a later turn.",
                  "parameters": {
                    "type": "object",
                    "properties": {
                      "job_id": {
                        "type": "integer",
                        "minimum": 1000,
                        "description": "Background agent job id."
                      },
                      "result_offset": {
                        "type": "integer",
                        "minimum": 0,
                        "description": "Stable UTF-8 byte offset into the persisted result. Use 0 for the first chunk; omit it to show execution details."
                      }
                    },
                    "required": [
                      "job_id"
                    ],
                    "additionalProperties": false
                  },
                  "execution_mode": "parallel",
                  "read_only": true,
                  "destructive": false
                },
                {
                  "type": "function",
                  "name": "send_message_to_background_job",
                  "run_kinds": ["main", "ambient", "scheduled", "workflow_task"],
                  "activity": "background_job_send",
                  "description": "Send a message to any live job: queued, running, or waiting_on_user. A queued message stays behind the original task and is applied when execution starts. wait_reply (default: true) observes the exact background Turn for up to wait_timeout_ms (default: 30s). timeout only ends foreground observation while the Job keeps running. set wait_reply=false if the Turn result is not needed immediately.",
                  "parameters": {
                    "type": "object",
                    "properties": {
                      "job_id": {
                        "type": "integer",
                        "minimum": 1000,
                        "description": "Background agent job id."
                      },
                      "message": {
                        "type": "string",
                        "minLength": 1,
                        "description": "Message to send to the background agent job."
                      },
                      "wait_reply": {
                        "default": true,
                        "type": "boolean",
                        "description": "Wait for the Codex Turn that receives this message."
                      },
                      "wait_timeout_ms": {
                        "default": 30000,
                        "type": "integer",
                        "minimum": 10000,
                        "maximum": 150000,
                        "description": "Foreground observation window in milliseconds. The background job keeps running after it expires."
                      }
                    },
                    "required": [
                      "job_id",
                      "message",
                      "wait_reply",
                      "wait_timeout_ms"
                    ],
                    "additionalProperties": false
                  },
                  "execution_mode": "sequential",
                  "read_only": false,
                  "destructive": false
                },
                {
                  "type": "function",
                  "name": "respawn_background_job",
                  "activity": "background_job_respawn",
                  "description": "Respawn one non-running background agent job as a new one. It uses the same workspace and thread, and sends the message as the next user input.",
                  "parameters": {
                    "type": "object",
                    "properties": {
                      "source_job_id": {
                        "type": "integer",
                        "minimum": 1000,
                        "description": "Terminal background agent job id to respawn."
                      },
                      "message": {
                        "type": "string",
                        "minLength": 1
                      }
                    },
                    "required": [
                      "source_job_id",
                      "message"
                    ],
                    "additionalProperties": false
                  },
                  "execution_mode": "sequential",
                  "read_only": false,
                  "destructive": false
                },
                {
                  "type": "function",
                  "name": "stop_background_job",
                  "run_kinds": ["main", "ambient", "scheduled", "workflow_task"],
                  "activity": "background_job_stop",
                  "description": "Stop running job. A terminal job is an idempotent no-op.",
                  "parameters": {
                    "type": "object",
                    "properties": {
                      "job_id": {
                        "type": "integer",
                        "minimum": 1000,
                        "description": "Background agent job id."
                      }
                    },
                    "required": [
                      "job_id"
                    ],
                    "additionalProperties": false
                  },
                  "execution_mode": "sequential",
                  "read_only": false,
                  "destructive": true
                }
                ]
                """)
  @impl true
  def declarations, do: @declarations
  @impl true
  def declarations(run) do
    profiles = run.spec.request_context["custom_model_profiles"] || []

    templates =
      run.context.agent_plugins
      |> Enum.filter(& &1["has_workspace_template"])
      |> Enum.sort_by(& &1["id"])

    Enum.map(@declarations, fn
      %{"name" => "create_background_job"} = tool ->
        tool = Ankole.Sessions.Tool.with_profiles(tool, profiles, "coding")

        description =
          if templates == [],
            do: "No workspace template is available; omit workspace_template_id.",
            else:
              "Available workspace templates: " <>
                Enum.map_join(
                  templates,
                  ", ",
                  &"#{&1["id"]} (#{Ankole.Sessions.Prompt.catalog_line(&1["description"], 400)})"
                ) <> ". Omit workspace_template_id to use no template."

        tool = Map.update!(tool, "description", &(&1 <> " " <> description))

        if templates == [],
          do: tool,
          else:
            put_in(tool, ["parameters", "properties", "workspace_template_id"], %{
              "type" => "string",
              "enum" => Enum.map(templates, & &1["id"])
            })

      tool ->
        tool
    end)
  end

  @impl true
  def activity(%{name: "send_message_to_background_job"}, args, "completed", result) do
    key =
      case result.details do
        %{"wait_outcome" => "timed_out"} -> "background_job_async"
        %{"wait_outcome" => "steered"} -> "background_job_steered"
        %{"wait_outcome" => _outcome} -> "background_job_replied"
        _ -> if(args["wait_reply"], do: "background_job_replied", else: "background_job_sent")
      end

    {key, %{}}
  end

  def activity(tool, args, _phase, _result), do: {tool.activity, Map.take(args, ["name"])}

  alias Ankole.BackgroundAgentJobs, as: Jobs
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.Sessions.Run
  alias Ankole.Sessions.Tools
  alias Ankole.Conversations.Route

  @impl true
  def normalize("send_message_to_background_job", args) when is_map(args) do
    args
    |> Map.put_new("wait_reply", true)
    |> Map.put_new("wait_timeout_ms", 30_000)
  end

  def normalize(_name, args), do: args

  @impl true
  def execute(run, %{"name" => "list_background_jobs"}, args) do
    with {:ok, cursor} <- Tools.cursor(run, "background agent job", args["page"]),
         {:ok, value} <-
           Jobs.list_for_agent(run.agent_uid, status: args["status"] || "live", cursor: cursor) do
      jobs =
        Enum.map(
          value.jobs,
          &%{"job_id" => &1.job_id, "title" => &1.title, "status" => &1.status}
        )

      {:ok,
       Tools.result(%{"jobs" => jobs},
         cursor: {"background agent job", value.next_cursor}
       )}
    end
  end

  def execute(
        run,
        %{"name" => "show_background_job_details"},
        %{"result_offset" => offset} = args
      ) do
    case Jobs.get_result_window_for_agent(args["job_id"], run.agent_uid, offset) do
      %{
        job: %Job{status: :succeeded} = job,
        output_window: text,
        total_bytes: total,
        result_paths: paths
      }
      when is_binary(text) and is_integer(total) ->
        paths = bounded_paths(paths)

        Tools.window(Ankole.Text.utf8_prefix(text, byte_size(text)), offset, total, fn text,
                                                                                       next ->
          Map.merge(
            %{
              "title" => job.title,
              "status" => Atom.to_string(job.status),
              "result_ref" => %{"type" => "background_agent_job", "job_id" => job.id},
              "workspace_owner_job_id" => job.workspace_owner_job_id,
              "result" => %{"offset" => offset, "output_text" => text, "next_offset" => next}
            },
            paths
          )
        end)

      nil ->
        {:error, :job_not_found}

      %{job: job} ->
        {:error,
         "background agent job #{job.id} has status #{job.status}; only succeeded jobs have output"}
    end
  end

  def execute(run, %{"name" => "show_background_job_details"}, args) do
    with {:ok, value} <-
           Jobs.get_job_summary_for_agent(args["job_id"], run.agent_uid, trajectory_limit: 3) do
      job = value.job
      e = Ankole.JSON.plain(value.execution)

      details = %{
        "title" => job.title,
        "status" => Atom.to_string(job.status),
        "result_ref" =>
          if(job.status == :succeeded,
            do: %{"type" => "background_agent_job", "job_id" => job.id}
          ),
        "continued_from_job_id" => job.continued_from_job_id,
        "workspace_owner_job_id" => job.workspace_owner_job_id,
        "attempts" => job.attempts,
        "current_attempt" => e["attempt"],
        "current_turn_status" => get_in(e, ["current", "status"]),
        "threads" => e["threads"],
        "turns" => Map.take(e["turns"], ~w(lead child active)),
        "progress" => e["progress"],
        "usage" => e["usage"],
        "updated_at" => e["updated_at"],
        "error" => visible_error(job.error) || visible_error(get_in(e, ["current", "error"])),
        "attempt_history" => Ankole.JSON.plain(value.attempt_history),
        "recent_trajectory" => visible_trajectory(e["trajectory_page"])
      }

      {:ok, Tools.result(details)}
    end
  end

  @impl true
  def prepare_in_tx(run, %{"name" => "create_background_job"} = call, args) do
    attrs =
      Map.take(args, ~w(title task model_profile workspace_template_id))
      |> Map.put("title", String.trim(args["title"]))
      |> Map.merge(origin(run, call))

    if args["workspace_template_id"] &&
         not Enum.any?(
           run.context.agent_plugins,
           &(&1["has_workspace_template"] and &1["id"] == args["workspace_template_id"])
         ) do
      {:error, "no matching workspace template is available"}
    else
      Ankole.BackgroundAgentJobs.Dispatch.prepare_create_in_tx(attrs)
      |> project_prepared(&job_result/1)
    end
  end

  def prepare_in_tx(run, %{"name" => "respawn_background_job"} = call, args) do
    Ankole.BackgroundAgentJobs.Dispatch.prepare_respawn_in_tx(
      args["source_job_id"],
      Map.merge(origin(run, call), %{"message" => args["message"]})
    )
    |> project_prepared(&job_result/1)
  end

  def prepare_in_tx(run, %{"name" => "stop_background_job"}, args) do
    Ankole.BackgroundAgentJobs.Control.prepare_stop_in_tx(args["job_id"], %{
      "agent_uid" => run.agent_uid,
      "cancel_requested_by" => "agent:#{run.agent_uid}"
    })
    |> project_prepared(fn value ->
      {:ok, result, after_commit} = job_result(value)

      {:ok, result,
       after_commit ++ [fn -> Ankole.Sessions.stop_job_turn(value.job, value.turn) end]}
    end)
  end

  def prepare_in_tx(run, %{"name" => "send_message_to_background_job"} = call, args) do
    Ankole.BackgroundAgentJobs.Control.prepare_message_in_tx(args["job_id"], %{
      "agent_uid" => run.agent_uid,
      "request_id" => Run.tool_identity(run, call),
      "source_signal_id" => Route.current_input_signal_id(run),
      "message" => args["message"]
    })
    |> project_prepared(fn value ->
      details = %{"job_id" => value.job.id, "status" => Atom.to_string(value.job.status)}

      result =
        if Map.get(args, "wait_reply", true) do
          {:await,
           %Ankole.Sessions.Wait{
             kind: :job,
             job_id: value.job.id,
             command_event_id: value.command_event.id,
             timeout_ms: args["wait_timeout_ms"] || 30_000
           }}
        else
          Tools.result(details,
            text:
              "Message stored for background job #{value.job.id}. Current job status: #{value.job.status}."
          )
        end

      {:ok, result, []}
    end)
  end

  defp job_result(value) do
    {:ok, Tools.result(%{"job_id" => value.job.id, "status" => Atom.to_string(value.job.status)}),
     []}
  end

  defp project_prepared({:ok, sessions, commit}, project) do
    {:ok, sessions, fn -> with {:ok, value} <- commit.(), do: project.(value) end}
  end

  defp project_prepared({:error, _} = error, _project), do: error

  @impl true
  def observe(run, wait, steered?, expired?) do
    with %Ankole.BackgroundAgentJobs.Schemas.Job{} = job <-
           Jobs.get_job_for_agent(wait.job_id, run.agent_uid),
         {:ok, observed} <- Jobs.message_result(job, wait.command_event_id, run.session_id) do
      cond do
        id = observed[:successor_job_id] ->
          details = %{
            "job_id" => job.id,
            "status" => Atom.to_string(observed.status),
            "successor_job_id" => id,
            "continues_running" => true,
            "reply_ready" => false,
            "wait_outcome" => "forwarded"
          }

          {:ready,
           Tools.result(details,
             text:
               "Background job #{job.id} finished before it read this message. Successor background job #{id} continues the work with it; its result arrives as a separate notification. Do not resend the message."
           ), []}

        observed.ready ->
          trajectory = visible_trajectory(Ankole.JSON.plain(observed.last_turn_trajectory))
          continues? = observed.status == :running

          details = %{
            "job_id" => job.id,
            "status" => Atom.to_string(observed.status),
            "last_turn_trajectory" => trajectory,
            "earlier_trajectory_omitted" => observed.earlier_trajectory_omitted,
            "continues_running" => continues?,
            "reply_ready" => true,
            "wait_outcome" => "reply_ready"
          }

          text =
            [
              "Last turn trajectory:\n#{Ankole.JSON.encode!(trajectory)}",
              if(observed.earlier_trajectory_omitted,
                do: "Earlier trajectory items were omitted."
              ),
              if(continues?, do: "The job continues to run in the background.")
            ]
            |> Enum.reject(&is_nil/1)
            |> Enum.join("\n")

          {:ready, Tools.result(details, text: text), List.wrap(observed.lifecycle_signal_id)}

        steered? or expired? ->
          continues? = observed.status not in [:succeeded, :failed, :stopped]
          outcome = if steered?, do: "steered", else: "timed_out"

          reason =
            if steered?,
              do: "new user steering is pending",
              else: "the foreground observation window expired"

          details = %{
            "job_id" => job.id,
            "status" => Atom.to_string(observed.status),
            "continues_running" => continues?,
            "reply_ready" => false,
            "wait_outcome" => outcome
          }

          text =
            [
              "Stopped waiting for background job #{job.id} because #{reason}.",
              "Current job status: #{observed.status}.",
              "The message is already stored; do not resend it.",
              if(continues?, do: "The job continues to run in the background.")
            ]
            |> Enum.reject(&is_nil/1)
            |> Enum.join("\n")

          {:ready, Tools.result(details, text: text), []}

        true ->
          :pending
      end
    else
      {:error, reason} -> {:ready, Tools.error(reason), []}
      nil -> {:ready, Tools.error(:job_not_found), []}
    end
  end

  defp visible_trajectory(nil), do: nil

  defp visible_trajectory(trajectory) do
    {messages, _aliases} =
      Enum.map_reduce(trajectory["messages"] || [], %{}, fn message, aliases ->
        message = Map.delete(message, "id")

        {message, aliases} =
          if is_list(message["tool_calls"]) do
            {calls, aliases} =
              Enum.map_reduce(message["tool_calls"], aliases, fn call, aliases ->
                if is_binary(call["id"]) do
                  {name, aliases} = call_alias(aliases, call["id"])
                  {Map.put(call, "id", name), aliases}
                else
                  {call, aliases}
                end
              end)

            {Map.put(message, "tool_calls", calls), aliases}
          else
            {message, aliases}
          end

        if message["role"] == "tool" and is_binary(message["tool_call_id"]) do
          {name, aliases} = call_alias(aliases, message["tool_call_id"])
          {Map.put(message, "tool_call_id", name), aliases}
        else
          {message, aliases}
        end
      end)

    Map.put(trajectory, "messages", messages)
  end

  defp call_alias(aliases, id) do
    name = aliases[id] || "call_#{map_size(aliases) + 1}"
    {name, Map.put(aliases, id, name)}
  end

  defp origin(run, call),
    do: %{
      "agent_uid" => run.agent_uid,
      "owner_session_id" => run.session_id,
      "source_signal_id" => Route.current_input_signal_id(run),
      "source_tool_call_id" => Run.tool_identity(run, call),
      "reply_route" => Route.snapshot(run)
    }

  defp visible_error(nil), do: nil

  defp visible_error(error) do
    error =
      Map.put(error, "summary", error["summary"] || error["message"])
      |> Map.take(~w(code summary retryable codex_turn_status))
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new(fn {k, v} ->
        {k,
         if(is_binary(v),
           do:
             Regex.replace(
               ~r/\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b/i,
               v,
               "[internal-id]"
             ),
           else: v
         )}
      end)

    if error != %{}, do: error
  end

  defp bounded_paths(paths) do
    paths = Map.new(~w(project_path artifacts artifact_roots), &{&1, paths[&1]})

    if byte_size(Ankole.JSON.encode!(paths)) <= 2_000 do
      paths
    else
      key =
        if get_in(paths, ["artifact_roots", "paths"]) not in [nil, []],
          do: "artifact_roots",
          else: "artifacts"

      case paths[key] do
        %{"paths" => [_ | _] = entries} = value ->
          bounded_paths(
            Map.put(
              paths,
              key,
              %{value | "paths" => Enum.drop(entries, -1)} |> Map.put("truncated", true)
            )
          )

        _ ->
          paths
      end
    end
  end
end
