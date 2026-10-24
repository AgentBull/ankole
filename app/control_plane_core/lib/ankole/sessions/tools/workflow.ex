defmodule Ankole.Sessions.Tools.Workflow do
  @behaviour Ankole.Sessions.Tool
  @moduledoc false
  @declarations Ankole.JSON.decode!(~S"""
                [
                {
                  "type": "function",
                  "name": "workflow",
                  "activity": "workflow_create",
                  "description": "Run a bounded JavaScript orchestration that fans work out to independent subagents and wakes this conversation when the run finishes. The script starts with its persisted input object as args and calls await agent(prompt, { label?, model_profile?, schema? }); a successful call resolves to its structured value and a failed call resolves to null. Use Promise.all for parallel fanout, handle null explicitly, and return the final value from the script. Each attempt is one real subagent turn; one agent() call can use up to three attempts, so give each call a meaningful task and set concurrency and max_agent_calls deliberately. The script must terminate: use finite input arrays and explicit loop bounds, and do not poll or wait for external state. A result schema must use the supported OpenAPI-compatible JSON Schema subset and cannot allow null. Every object must set additionalProperties to false and list every property name in required.",
                  "parameters": {
                    "type": "object",
                    "properties": {
                      "title": {
                        "type": "string",
                        "minLength": 1,
                        "maxLength": 200
                      },
                      "script": {
                        "type": "string",
                        "minLength": 1
                      },
                      "args": {
                        "type": "object",
                        "propertyNames": {
                          "type": "string"
                        },
                        "additionalProperties": {}
                      },
                      "concurrency": {
                        "type": "integer",
                        "minimum": 1,
                        "maximum": 32
                      },
                      "max_agent_calls": {
                        "type": "integer",
                        "minimum": 1,
                        "maximum": 1024
                      }
                    },
                    "required": [
                      "title",
                      "script"
                    ],
                    "additionalProperties": false
                  },
                  "execution_mode": "sequential",
                  "read_only": false,
                  "destructive": false
                },
                {
                  "type": "function",
                  "name": "show_workflow",
                  "activity": "workflow_show",
                  "description": "Show a Workflow run, including task counts, live tasks, bounded failure summaries, and a terminal error. A sleeping task is still executing: it hibernates until an event wakes it, and its note states what it waits for. A task with attention=true waits for your input; answer it with send_message_to_workflow_task. To read a completed result, set result_offset to 0, concatenate result.output_text, and pass result.next_offset to the next call until it is null. Result offsets are stable and can be resumed in a later turn.",
                  "parameters": {
                    "type": "object",
                    "properties": {
                      "run_id": {
                        "type": "integer",
                        "minimum": 1000,
                        "description": "Workflow run id."
                      },
                      "result_offset": {
                        "type": "integer",
                        "minimum": 0,
                        "description": "Stable UTF-8 byte offset into the persisted result. Start with 0 and follow result.next_offset."
                      }
                    },
                    "required": [
                      "run_id"
                    ],
                    "additionalProperties": false
                  },
                  "execution_mode": "parallel",
                  "read_only": true,
                  "destructive": false
                },
                {
                  "type": "function",
                  "name": "list_workflows",
                  "activity": "workflow_list",
                  "description": "List Workflow runs owned by the current Agent. status defaults to live. live includes running; done includes completed, failed, and cancelled. Each page contains at most 32 runs, newest first. Use next_page to continue.",
                  "parameters": {
                    "type": "object",
                    "properties": {
                      "status": {
                        "type": "string",
                        "enum": [
                          "live",
                          "done"
                        ],
                        "description": "Workflow group. live includes running; done includes completed, failed, and cancelled."
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
                  "name": "send_message_to_workflow_task",
                  "activity": "workflow_task_message",
                  "description": "Send a message to one live Workflow task, addressed by run_id and call_seq from show_workflow. The send is asynchronous and returns immediately: a sleeping task wakes with the message, a running task receives it when its current turn ends. Use it to answer a task that sleeps with attention, or to steer a task mid-run. It cannot reach a terminal task.",
                  "parameters": {
                    "type": "object",
                    "properties": {
                      "run_id": {
                        "type": "integer",
                        "minimum": 1000,
                        "description": "Workflow run id."
                      },
                      "call_seq": {
                        "type": "integer",
                        "minimum": 0,
                        "description": "Task call_seq from show_workflow."
                      },
                      "message": {
                        "type": "string",
                        "minLength": 1,
                        "maxLength": 8000,
                        "description": "Message delivered to the task."
                      }
                    },
                    "required": [
                      "run_id",
                      "call_seq",
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
                  "name": "cancel_workflow",
                  "activity": "workflow_cancel",
                  "description": "Cancel a running Workflow. A terminal Workflow is an idempotent no-op.",
                  "parameters": {
                    "type": "object",
                    "properties": {
                      "run_id": {
                        "type": "integer",
                        "minimum": 1000,
                        "description": "Workflow run id."
                      }
                    },
                    "required": [
                      "run_id"
                    ],
                    "additionalProperties": false
                  },
                  "execution_mode": "sequential",
                  "read_only": false,
                  "destructive": true
                },
                {
                  "type": "function",
                  "name": "sleep",
                  "run_kinds": ["workflow_task"],
                  "ends_run": true,
                  "activity": "workflow_task_sleep",
                  "description": "Hibernate this Workflow task and end the current turn. The task stays non-terminal and holds no worker slot. Any of these wakes it into a new turn with this conversation intact: the wake_after_ms deadline, a message from the main Agent, or a lifecycle event from a background job this task created. Sleep after create_background_job instead of waiting in this turn. The wake budget is bounded, so sleep for the expected wait instead of polling with short sleeps.",
                  "parameters": {
                    "type": "object",
                    "properties": {
                      "wake_after_ms": {
                        "type": "integer",
                        "minimum": 60000,
                        "maximum": 172800000,
                        "description": "Guaranteed wake deadline in milliseconds. Events can wake the task earlier."
                      },
                      "note": {
                        "type": "string",
                        "minLength": 1,
                        "maxLength": 200,
                        "description": "What this task waits for. The main Agent sees this note in show_workflow."
                      },
                      "attention": {
                        "default": false,
                        "description": "Set true only when the task cannot proceed without main-Agent input.",
                        "type": "boolean"
                      }
                    },
                    "required": [
                      "wake_after_ms",
                      "note",
                      "attention"
                    ],
                    "additionalProperties": false
                  },
                  "execution_mode": "sequential",
                  "read_only": false,
                  "destructive": false
                },
                {
                  "type": "function",
                  "name": "submit_result",
                  "run_kinds": ["workflow_task"],
                  "ends_run": true,
                  "activity": "submit_result",
                  "description": "Submit the final result of this Workflow task. Call this tool only after the task is complete. A schema rejection is recoverable: correct the result and call the tool again. An accepted result ends this task turn.",
                  "parameters": {
                    "type": "object",
                    "properties": {
                      "result": {
                        "type": "string"
                      }
                    },
                    "required": [
                      "result"
                    ],
                    "additionalProperties": false
                  },
                  "strict": true,
                  "execution_mode": "sequential",
                  "read_only": false,
                  "destructive": false
                }
                ]
                """)
  @impl true
  def declarations, do: @declarations
  @impl true
  def declarations(run) do
    Enum.map(@declarations, fn
      %{"name" => "workflow"} = tool ->
        Ankole.Sessions.Tool.with_profiles(
          tool,
          run.spec.request_context["custom_model_profiles"] || [],
          "primary"
        )

      %{"name" => "submit_result"} = tool ->
        put_in(tool, ["parameters", "properties", "result"], run.spec.request_context["schema"])

      tool ->
        tool
    end)
  end

  @impl true
  def normalize("sleep", args), do: Map.put_new(args, "attention", false)
  def normalize(_name, args), do: args

  alias Ankole.Sessions.Tools
  alias Ankole.Workflow

  @impl true
  def execute(run, %{"name" => "show_workflow"}, args) do
    with {:ok, value} <-
           Workflow.get(
             args["run_id"],
             run.agent_uid,
             if(Map.has_key?(args, "result_offset"),
               do: [result_offset: args["result_offset"]],
               else: []
             )
           ) do
      job = value.run

      if Map.has_key?(args, "result_offset") do
        if job.status != :completed do
          {:error,
           "Workflow #{job.id} has status #{job.status}; only completed Workflows have result output"}
        else
          Tools.window(
            value.result_output_text,
            args["result_offset"],
            value.result_output_total_bytes,
            fn text, next ->
              %{
                "run_id" => job.id,
                "title" => job.title,
                "status" => Atom.to_string(job.status),
                "result" => %{
                  "offset" => args["result_offset"],
                  "output_text" => text,
                  "next_offset" => next
                }
              }
            end
          )
        end
      else
        {:ok,
         Tools.result(%{
           "run_id" => job.id,
           "title" => job.title,
           "status" => Atom.to_string(job.status),
           "counts" => Ankole.JSON.plain(value.counts),
           "live_tasks" => Ankole.JSON.plain(value.live_tasks),
           "failure_summaries" => Ankole.JSON.plain(value.failure_summaries),
           "error" => if(job.error == %{}, do: nil, else: job.error)
         })}
      end
    end
  end

  def execute(run, %{"name" => "list_workflows"}, args) do
    with {:ok, cursor} <- Tools.cursor(run, "Workflow", args["page"]),
         {:ok, value} <-
           Workflow.list(run.agent_uid, status: args["status"] || "live", cursor: cursor) do
      {:ok,
       Tools.result(
         %{"runs" => value.runs},
         cursor: {"Workflow", value.next_cursor}
       )}
    end
  end

  @impl true
  def prepare_in_tx(run, call, args) do
    with {:ok, sessions, commit} <-
           Ankole.Workflow.ToolAdmission.prepare_in_tx(run, call, args) do
      {:ok, sessions,
       fn ->
         with {:ok, value} <- commit.(), do: prepared_result(call["name"], value)
       end}
    end
  end

  defp prepared_result(name, value) when name in ["workflow", "cancel_workflow"] do
    actions =
      if name == "cancel_workflow",
        do: [fn -> Workflow.cleanup_terminal_transition({:ok, value}) end],
        else: []

    {:ok, Tools.result(%{"run_id" => value.run.id, "status" => Atom.to_string(value.run.status)}),
     actions}
  end

  defp prepared_result("send_message_to_workflow_task", value) do
    {:ok,
     Tools.result(%{
       "run_id" => value.run.id,
       "call_seq" => value.call.call_seq,
       "task_status" => Atom.to_string(value.call.status)
     }), []}
  end

  defp prepared_result("submit_result", value) do
    {:ok,
     Tools.result(
       %{"accepted" => value.accepted, "task_status" => Atom.to_string(value.call.status)},
       terminate: true,
       outcome: :submitted
     ), [fn -> Workflow.cleanup_terminal_transition({:ok, value}) end]}
  end

  defp prepared_result("sleep", value) do
    {:ok,
     Tools.result(
       %{
         "task_status" => Atom.to_string(value.call.status),
         "wake_count" => value.call.wake_count
       },
       terminate: true,
       outcome: :sleeping
     ), [fn -> Workflow.cleanup_terminal_transition({:ok, value}) end]}
  end
end
