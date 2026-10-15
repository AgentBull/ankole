defmodule Ankole.Sessions.Tools.Schedule do
  @behaviour Ankole.Sessions.Tool
  @moduledoc false
  @declarations Ankole.JSON.decode!(~S"""
                [
                {
                  "type": "function",
                  "name": "check_back_later",
                  "activity": "schedule_follow_up",
                  "receipt_read_actions": ["list", "get", "runs"],
                  "description": "Manage one-shot delayed self-wakeups for this conversation (create, list, inspect, update, cancel pending checkbacks).\nUse when asked to wait, remind yourself, follow up later, re-check after time passes, or modify/cancel scheduled checkbacks.\nupdate only modifies provided fields.\nConversational corrections alone don't change durable work. Never claim creation, update, or cancellation until tool confirms success.\nIf you judge that a script you write could perform this trigger's check equally well and at lower token cost than waking you each time, run `create-automation-job-cli --help` before creating the trigger to confirm the fit. The script can still wake you when its result needs judgment.",
                  "parameters": {
                    "type": "object",
                    "properties": {
                      "action": {
                        "type": "string",
                        "enum": [
                          "create",
                          "list",
                          "get",
                          "update",
                          "cancel"
                        ],
                        "description": "Checkback management action."
                      },
                      "checkback_id": {
                        "description": "Required for get, update, and cancel. Use list first when the id is unknown.",
                        "type": "integer",
                        "minimum": 1000
                      },
                      "reason": {
                        "description": "Required for create: why the checkback is useful.",
                        "type": "string",
                        "minLength": 1,
                        "maxLength": 2000
                      },
                      "check": {
                        "description": "Required for create: what to do at wakeup.",
                        "type": "string",
                        "minLength": 1,
                        "maxLength": 4000
                      },
                      "context_summary": {
                        "description": "Optional compact context carried to the wakeup. On update, null clears it.",
                        "anyOf": [
                          {
                            "type": "string",
                            "maxLength": 8000
                          },
                          {
                            "type": "null"
                          }
                        ]
                      },
                      "schedule": {
                        "description": "Required for create: the one-shot wakeup time.",
                        "anyOf": [
                          {
                            "type": "object",
                            "properties": {
                              "after": {
                                "type": "object",
                                "properties": {
                                  "value": {
                                    "type": "integer",
                                    "exclusiveMinimum": 0
                                  },
                                  "unit": {
                                    "type": "string",
                                    "enum": [
                                      "millisecond",
                                      "second",
                                      "minute",
                                      "hour",
                                      "day",
                                      "week"
                                    ]
                                  }
                                },
                                "required": [
                                  "value",
                                  "unit"
                                ],
                                "additionalProperties": false,
                                "description": "Relative delay for genuinely relative requests. Do not round a known clock time, market close, deadline, or timezone-converted instant into an approximate delay."
                              },
                              "timezone": {
                                "type": "string"
                              }
                            },
                            "required": [
                              "after"
                            ],
                            "additionalProperties": false
                          },
                          {
                            "type": "object",
                            "properties": {
                              "at": {
                                "type": "string",
                                "description": "Exact absolute ISO datetime, or local ISO datetime with timezone. Prefer at whenever the requested event has a known clock time or deadline."
                              },
                              "timezone": {
                                "description": "Timezone for local at values.",
                                "type": "string"
                              }
                            },
                            "required": [
                              "at"
                            ],
                            "additionalProperties": false
                          }
                        ]
                      },
                      "quiet_success": {
                        "description": "Allow finishing without a visible reply when nothing needs attention. Set true only when the user explicitly asked for no update on normal/no-change outcomes; failures, blockers, human decisions, meaningful changes, and time-sensitive risks stay visible.",
                        "type": "boolean"
                      },
                      "automation_job_id": {
                        "description": "Optional automation job that consumes this trigger. On update, null detaches it.",
                        "anyOf": [
                          {
                            "type": "integer",
                            "minimum": 1000
                          },
                          {
                            "type": "null"
                          }
                        ]
                      },
                      "limit": {
                        "description": "Optional list result limit, at most 25.",
                        "type": "integer",
                        "exclusiveMinimum": 0,
                        "maximum": 25
                      }
                    },
                    "required": [
                      "action"
                    ],
                    "additionalProperties": false
                  },
                  "execution_mode": "sequential",
                  "read_only": false,
                  "destructive": false
                },
                {
                  "type": "function",
                  "name": "cron",
                  "activity": "schedule_follow_up",
                  "receipt_read_actions": ["list", "get", "runs"],
                  "description": "Manage recurring schedules created from this conversation (list, inspect, create, update, pause, resume, remove, run, view history).\nUse when asked about standing work, recurring tasks, monitors, routines, scheduled jobs, or cron follow-ups.\nEach schedule runs in its own scheduled-task session, not in this conversation: fires never see this transcript, and Ankole delivers their replies to the configured conversation.\npayload.task must therefore carry the complete standing instruction (goal, inputs, constraints, output form) unless automation_job_id consumes the trigger.\nSupports kind=every/cron only. For bounded repetitions (\"ten times\", \"until Sept\"), set schedule.occurrences with count/until (auto-completes when spent). For work that stops once a condition is met (\"until the PR merges\"), write the condition into payload.task; a fire that finds it met pauses its own schedule.\nUpdating payload or delivery starts a new model conversation for the scheduled-task session on the next fire; existing run history remains. Schedule or timezone changes keep the current conversation.\nAfter add/update, summarize in visible reply: name, schedule/timezone, and quiet_success status.\nSchedules are addressed by name; they have no user-facing id, so answer an id request with the name. Report delivery reach from delivery_target_count in the result, and never state a count the result does not contain.\nUse quiet_success=true for monitors to stay quiet on success and report only failures, blockers, or state changes.\nIf you judge that a script you write could perform this trigger's check equally well and at lower token cost than waking you each time, run `create-automation-job-cli --help` before creating the trigger to confirm the fit. The script can still wake you when its result needs judgment.\nIn principle, a polling interval of less than 30 minutes should only be used for script tasks (create-automation-job), as frequently waking up an LLM can be quite costly.",
                  "parameters": {
                    "type": "object",
                    "properties": {
                      "action": {
                        "type": "string",
                        "enum": [
                          "list",
                          "get",
                          "runs",
                          "add",
                          "update",
                          "pause",
                          "resume",
                          "remove",
                          "run"
                        ]
                      },
                      "name": {
                        "type": "string",
                        "minLength": 1
                      },
                      "schedule": {
                        "anyOf": [
                          {
                            "type": "object",
                            "properties": {
                              "kind": {
                                "type": "string",
                                "const": "every"
                              },
                              "every_ms": {
                                "type": "integer",
                                "exclusiveMinimum": 0
                              },
                              "anchor_at": {
                                "type": "string"
                              },
                              "occurrences": {
                                "anyOf": [
                                  {
                                    "type": "object",
                                    "properties": {
                                      "count": {
                                        "type": "integer",
                                        "exclusiveMinimum": 0
                                      }
                                    },
                                    "required": [
                                      "count"
                                    ],
                                    "additionalProperties": false
                                  },
                                  {
                                    "type": "object",
                                    "properties": {
                                      "until": {
                                        "type": "string",
                                        "minLength": 1
                                      }
                                    },
                                    "required": [
                                      "until"
                                    ],
                                    "additionalProperties": false
                                  }
                                ],
                                "description": "Optional finite bound for the recurrence: count is a budget of due occurrences (a due occurrence spends it whether its delivery then succeeds or fails; retries of one occurrence spend nothing more), until is an inclusive cutoff instant (ISO 8601, or a local wall-clock time resolved in the schedule timezone). Give one or the other, never both. The schedule reports status completed once the bound is spent."
                              }
                            },
                            "required": [
                              "kind",
                              "every_ms",
                              "anchor_at"
                            ],
                            "additionalProperties": false
                          },
                          {
                            "type": "object",
                            "properties": {
                              "kind": {
                                "type": "string",
                                "const": "cron"
                              },
                              "expression": {
                                "type": "string",
                                "minLength": 1
                              },
                              "timezone": {
                                "type": "string"
                              },
                              "occurrences": {
                                "anyOf": [
                                  {
                                    "type": "object",
                                    "properties": {
                                      "count": {
                                        "type": "integer",
                                        "exclusiveMinimum": 0
                                      }
                                    },
                                    "required": [
                                      "count"
                                    ],
                                    "additionalProperties": false
                                  },
                                  {
                                    "type": "object",
                                    "properties": {
                                      "until": {
                                        "type": "string",
                                        "minLength": 1
                                      }
                                    },
                                    "required": [
                                      "until"
                                    ],
                                    "additionalProperties": false
                                  }
                                ],
                                "description": "Optional finite bound for the recurrence: count is a budget of due occurrences (a due occurrence spends it whether its delivery then succeeds or fails; retries of one occurrence spend nothing more), until is an inclusive cutoff instant (ISO 8601, or a local wall-clock time resolved in the schedule timezone). Give one or the other, never both. The schedule reports status completed once the bound is spent."
                              }
                            },
                            "required": [
                              "kind",
                              "expression"
                            ],
                            "additionalProperties": false
                          }
                        ]
                      },
                      "payload": {
                        "description": "Schedule input. For a direct-Agent schedule, task (string) must carry the complete standing instruction: fires run outside this conversation and see only this payload.",
                        "type": "object",
                        "propertyNames": {
                          "type": "string"
                        },
                        "additionalProperties": {}
                      },
                      "delivery": {
                        "type": "object",
                        "properties": {
                          "quiet_success": {
                            "type": "boolean"
                          },
                          "targets": {
                            "description": "Reply destinations. Defaults to the current conversation.",
                            "type": "array",
                            "minItems": 1,
                            "items": {
                              "anyOf": [
                                {
                                  "type": "object",
                                  "properties": {"conversation_id": {"type": "string", "format": "uuid"}},
                                  "required": ["conversation_id"],
                                  "additionalProperties": false
                                },
                                {
                                  "type": "object",
                                  "properties": {
                                    "binding_name": {"type": "string"},
                                    "conversation_id": {"type": "string", "format": "uuid"},
                                    "provider_thread_id": {"type": "string"}
                                  },
                                  "required": ["binding_name", "conversation_id"],
                                  "additionalProperties": false
                                }
                              ]
                            }
                          }
                        },
                        "additionalProperties": false
                      },
                      "automation_job_id": {
                        "anyOf": [
                          {
                            "type": "integer",
                            "minimum": 1000
                          },
                          {
                            "type": "null"
                          }
                        ]
                      },
                      "limit": {
                        "type": "integer",
                        "exclusiveMinimum": 0,
                        "maximum": 100
                      }
                    },
                    "required": [
                      "action"
                    ],
                    "additionalProperties": false
                  },
                  "execution_mode": "sequential",
                  "read_only": false,
                  "destructive": false
                }
                ]
                """)
  @impl true
  def normalize(_name, args), do: args

  @impl true
  def declarations, do: @declarations
  @impl true
  def declarations(run) do
    if Ankole.Schedule.cron_execution_schedule_id(run.session_id) do
      Enum.map(@declarations, fn
        %{"name" => "cron"} = tool ->
          tool
          |> Map.put(
            "description",
            "Inspect or pause the recurring schedule that runs this conversation (list/get/runs/pause). When its task says to stop once a condition is met and you find the condition met, pause it. You cannot create, change, resume, run or remove schedules here."
          )
          |> put_in(["parameters", "properties", "action", "enum"], ~w(list get runs pause))
          |> update_in(["parameters", "properties"], &Map.take(&1, ~w(action name limit)))

        tool ->
          tool
      end)
    else
      @declarations
    end
  end

  alias Ankole.Schedule
  alias Ankole.Conversations.Route
  alias Ankole.Sessions.Run
  alias Ankole.Sessions.Tools

  @impl true
  def execute(run, call, args) do
    with :ok <- operation_arguments(call["name"], args),
         {:ok, payload} <- invoke(run, call, args),
         do: {:ok, Tools.result(payload, presentation: effect_presentation(call["name"], args))}
  end

  @impl true
  def execute_in_tx(_repo, run, call, args) do
    with {:ok, result} <- execute(run, call, args), do: {:ok, result, []}
  end

  defp invoke(run, call, args) do
    route = Ankole.Conversations.Route.snapshot(run)
    id = Run.tool_identity(run, call)

    updates =
      Map.take(
        args,
        if(call["name"] == "cron",
          do: ~w(schedule payload delivery automation_job_id),
          else: ~w(reason check context_summary quiet_success schedule automation_job_id)
        )
      )

    delivery = args["delivery"] || %{}

    target =
      Map.take(route, ~w(conversation_id binding_name provider_thread_id))

    delivery = if target == %{}, do: delivery, else: Map.put_new(delivery, "targets", [target])

    ctx = %{
      tool_call_id: id,
      idempotency_key: idempotency_key(run, call, args, updates, delivery),
      binding_name:
        (List.first(delivery["targets"] || []) || %{})["binding_name"] ||
          run.event.reply_binding_name,
      delivery: delivery,
      reply_route: route,
      updates: updates
    }

    operation(call["name"], args["action"], run, args, ctx)
  end

  defp idempotency_key(
         run,
         %{"name" => "check_back_later"},
         %{"action" => "create"} = args,
         _updates,
         _delivery
       ) do
    input = %{
      "signal_id" => run.signal_id,
      "reason" => String.trim(args["reason"]),
      "check" => String.trim(args["check"]),
      "context_summary" => String.trim(args["context_summary"] || ""),
      "schedule" => args["schedule"]
    }

    input =
      if args["quiet_success"] == true, do: Map.put(input, "quiet_success", true), else: input

    input =
      if Map.has_key?(args, "automation_job_id"),
        do: Map.put(input, "automation_job_id", args["automation_job_id"]),
        else: input

    "check_back_later:#{run.signal_id}:#{stable_hash(input)}"
  end

  defp idempotency_key(run, %{"name" => "cron"}, %{"action" => "add"} = args, _updates, delivery) do
    input = %{
      "signal_id" => run.signal_id,
      "binding_name" => run.event.reply_binding_name,
      "name" => String.trim(args["name"]),
      "schedule" => args["schedule"],
      "payload" => args["payload"] || %{},
      "delivery" => delivery,
      "automation_job_id" => args["automation_job_id"]
    }

    "cron:add:#{run.signal_id}:#{stable_hash(input)}"
  end

  defp idempotency_key(run, call, _args, _updates, _delivery),
    do: "#{call["name"]}:#{run.signal_id}:#{Run.tool_identity(run, call)}"

  defp stable_hash(value),
    do:
      :crypto.hash(:sha256, stable_json(value))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

  defp stable_json(value) when is_map(value),
    do: [
      "{",
      Enum.map_join(Enum.sort(value), ",", fn {key, item} ->
        Ankole.JSON.encode!(key) <> ":" <> IO.iodata_to_binary(stable_json(item))
      end),
      "}"
    ]

  defp stable_json(value) when is_list(value),
    do: ["[", Enum.map_join(value, ",", &IO.iodata_to_binary(stable_json(&1))), "]"]

  defp stable_json(value), do: Ankole.JSON.encode!(value)

  defp operation_arguments("check_back_later", args) do
    case args["action"] do
      "create" ->
        required(args, ~w(reason check schedule))

      action when action in ["get", "cancel"] ->
        required(args, ["checkback_id"])

      "update" ->
        with :ok <- required(args, ["checkback_id"]),
             do:
               require_updates(
                 args,
                 ~w(reason check context_summary quiet_success schedule automation_job_id)
               )

      "list" ->
        :ok
    end
  end

  defp operation_arguments("cron", args) do
    cond do
      args["action"] == "add" ->
        with :ok <- required(args, ~w(name schedule)),
             do:
               if(args["automation_job_id"],
                 do: :ok,
                 else: required(args["payload"] || %{}, ["task"])
               )

      args["action"] == "update" ->
        with :ok <- required(args, ["name"]),
             do: require_updates(args, ~w(schedule payload delivery automation_job_id))

      true ->
        :ok
    end
  end

  defp required(args, keys) do
    case Enum.find(keys, fn key ->
           args[key] in [nil, ""] or (is_binary(args[key]) and String.trim(args[key]) == "")
         end) do
      nil -> :ok
      key -> {:error, "#{key} is required"}
    end
  end

  defp require_updates(args, keys),
    do:
      if(Enum.any?(keys, &Map.has_key?(args, &1)),
        do: :ok,
        else: {:error, "provide at least one update"}
      )

  defp effect_presentation(name, args) do
    summaries = %{
      {"check_back_later", "create"} => "check_back_created",
      {"check_back_later", "update"} => "check_back_updated",
      {"check_back_later", "cancel"} => "check_back_cancelled",
      {"cron", "add"} => "cron_created",
      {"cron", "update"} => "cron_updated",
      {"cron", "pause"} => "cron_paused",
      {"cron", "resume"} => "cron_resumed",
      {"cron", "remove"} => "cron_removed",
      {"cron", "run"} => "cron_run_started"
    }

    case summaries[{name, args["action"]}] do
      nil ->
        []

      summary ->
        [
          %{
            "kind" => "effect.receipt",
            "payload" =>
              %{
                "phase" => "confirmed",
                "summary_key" => "conversations.delivery.reply.activity.#{summary}"
              }
              |> Map.merge(if(args["name"], do: %{"target" => args["name"]}, else: %{}))
          }
        ]
    end
  end

  defp operation("check_back_later", "create", turn_ref, args, ctx) do
    reply_route = ctx.reply_route

    with {:ok, source} <- Route.source(turn_ref),
         {:ok, attrs} <- checkback_attrs(args, ctx, turn_ref, source, reply_route),
         {:ok, %{status: status, scheduled_event: event}} <-
           Schedule.create_check_back_later(attrs) do
      {:ok,
       %{
         "status" => schedule_status(status),
         "due_at" => DateTime.to_iso8601(event.due_at),
         "timezone" => event.timezone,
         "quiet_success" => checkback_quiet_success(event)
       }}
    end
  end

  defp operation("check_back_later", "list", turn_ref, args, _ctx) do
    {:ok,
     %{
       "status" => "ok",
       "checkbacks" =>
         turn_ref.agent_uid
         |> Schedule.list_pending_checkbacks(
           turn_ref.session_id,
           args["limit"] || 10
         )
         |> Enum.map(&Schedule.event_model_projection/1)
     }}
  end

  defp operation("check_back_later", "get", turn_ref, args, _ctx) do
    with {:ok, event} <- checkback_from_turn(args["checkback_id"], turn_ref) do
      {:ok, %{"status" => "ok", "checkback" => Schedule.event_model_projection(event)}}
    end
  end

  defp operation("check_back_later", "update", turn_ref, args, ctx) do
    reply_route = ctx.reply_route

    with {:ok, event} <- checkback_from_turn(args["checkback_id"], turn_ref),
         {:ok, source} <- Route.source(turn_ref),
         {:ok, attrs} <- checkback_update_attrs(ctx, turn_ref, source, reply_route),
         {:ok, %{status: status, scheduled_event: updated}} <-
           Schedule.update_checkback(event.id, attrs) do
      {:ok,
       %{
         "status" => checkback_update_status(status),
         "checkback" => Schedule.event_model_projection(updated)
       }}
    end
  end

  defp operation("check_back_later", "cancel", turn_ref, args, _ctx) do
    with {:ok, event} <- checkback_from_turn(args["checkback_id"], turn_ref),
         {:ok, cancelled} <- Schedule.cancel_checkback(event.id) do
      {:ok,
       %{
         "status" => "cancelled",
         "checkback" => Schedule.event_model_projection(cancelled)
       }}
    end
  end

  defp operation("cron", "list", turn_ref, _args, _ctx) do
    {:ok,
     %{
       "status" => "ok",
       "schedules" =>
         turn_ref
         |> cron_schedules_for_turn()
         |> Enum.map(&Schedule.cron_model_projection/1)
     }}
  end

  defp operation("cron", "get", turn_ref, args, _ctx) do
    with {:ok, schedule} <- cron_schedule_from_turn(args["name"], turn_ref) do
      {:ok, %{"status" => "ok", "schedule" => Schedule.cron_model_projection(schedule)}}
    end
  end

  defp operation("cron", "runs", turn_ref, args, _ctx) do
    with {:ok, schedule} <- cron_schedule_from_turn(args["name"], turn_ref) do
      {:ok,
       %{
         "status" => "ok",
         "runs" =>
           schedule.id
           |> Schedule.list_cron_runs(args["limit"] || 25)
           |> Enum.map(&Schedule.event_model_projection/1)
       }}
    end
  end

  defp operation("cron", "add", turn_ref, args, ctx) do
    with {:ok, attrs} <- cron_attrs(args, ctx, turn_ref),
         created_by <- turn_created_by(turn_ref),
         {:ok, %{status: status, cron_schedule: schedule}} <-
           Schedule.create_cron_schedule(attrs, created_by: created_by) do
      {:ok,
       %{
         "status" => cron_create_status(status),
         "schedule" => Schedule.cron_model_projection(schedule)
       }}
    end
  end

  defp operation("cron", "update", turn_ref, args, ctx) do
    with {:ok, schedule} <- cron_schedule_from_turn(args["name"], turn_ref),
         updates <- ctx.updates || %{},
         {:ok, updated} <- Schedule.update_cron_schedule(schedule.id, updates) do
      {:ok, %{"status" => "updated", "schedule" => Schedule.cron_model_projection(updated)}}
    end
  end

  defp operation("cron", "pause", turn_ref, args, _ctx) do
    mutate_cron_from_turn(args["name"], turn_ref, "paused", &Schedule.pause_cron_schedule/1)
  end

  defp operation("cron", "resume", turn_ref, args, _ctx) do
    mutate_cron_from_turn(args["name"], turn_ref, "resumed", &Schedule.resume_cron_schedule/1)
  end

  defp operation("cron", "remove", turn_ref, args, _ctx) do
    mutate_cron_from_turn(args["name"], turn_ref, "removed", &Schedule.remove_cron_schedule/1)
  end

  defp operation("cron", "run", turn_ref, args, ctx) do
    with {:ok, schedule} <- cron_schedule_from_turn(args["name"], turn_ref),
         {:ok, %{status: status, scheduled_event: event}} <-
           Schedule.run_cron_schedule(schedule.id, tool_call_id: ctx.tool_call_id) do
      {:ok,
       %{
         "status" => schedule_status(status),
         "scheduled_event" => Schedule.event_model_projection(event)
       }}
    end
  end

  # A cron-origin turn runs in its schedule's execution session, which owns no
  # schedules. It resolves exactly its own definition, with or without the
  # name; owner turns resolve by owner session and name. The tool declaration
  # limits a cron-origin turn to list, get, runs and pause.
  defp cron_schedule_from_turn(name, %{} = turn_ref) do
    case {presence(name), cron_origin_schedule_id(turn_ref)} do
      {nil, nil} ->
        {:error, {:missing_text, :name}}

      {nil, origin_schedule_id} ->
        Schedule.get_cron_schedule(origin_schedule_id)

      {name, nil} ->
        Schedule.get_cron_schedule_by_name(turn_ref.agent_uid, turn_ref.session_id, name)

      {name, origin_schedule_id} ->
        with {:ok, schedule} <- Schedule.get_cron_schedule(origin_schedule_id) do
          case schedule.name == name do
            true -> {:ok, schedule}
            false -> {:error, :not_found}
          end
        end
    end
  end

  defp cron_schedules_for_turn(%{} = turn_ref) do
    case cron_origin_schedule_id(turn_ref) do
      nil ->
        Schedule.list_cron_schedules(turn_ref.agent_uid, turn_ref.session_id)

      origin_schedule_id ->
        case Schedule.get_cron_schedule(origin_schedule_id) do
          {:ok, %{status: "deleted"}} -> []
          {:ok, schedule} when schedule.agent_uid == turn_ref.agent_uid -> [schedule]
          _other -> []
        end
    end
  end

  defp checkback_from_turn(scheduled_event_id, %{} = turn_ref) do
    with {:ok, event} <- Schedule.get_checkback(scheduled_event_id),
         :ok <- checkback_belongs_to_turn(event, turn_ref) do
      {:ok, event}
    end
  end

  defp mutate_cron_from_turn(name, %{} = turn_ref, status, fun) do
    with {:ok, schedule} <- cron_schedule_from_turn(name, turn_ref),
         {:ok, updated} <- fun.(schedule.id) do
      {:ok, %{"status" => status, "schedule" => Schedule.cron_model_projection(updated)}}
    end
  end

  defp checkback_attrs(args, ctx, run, source, reply_route) do
    {:ok,
     Map.merge(checkback_turn_attrs(ctx, run, source, reply_route), %{
       "schedule" => args["schedule"],
       "reason" => args["reason"],
       "check" => args["check"],
       "context_summary" => args["context_summary"],
       "quiet_success" => args["quiet_success"] == true,
       "automation_job_id" => args["automation_job_id"]
     })}
  end

  defp checkback_update_attrs(ctx, run, source, reply_route),
    do: {:ok, Map.merge(ctx.updates, checkback_turn_attrs(ctx, run, source, reply_route))}

  defp checkback_turn_attrs(ctx, run, source, reply_route) do
    %{
      "agent_uid" => run.agent_uid,
      "session_id" => run.session_id,
      "binding_name" => reply_route["binding_name"] || source.binding_name,
      "tool_call_id" => ctx.tool_call_id,
      "idempotency_key" => ctx.idempotency_key,
      "reply_route" => reply_route,
      "origin_ai_message_id" => current_ai_message_id(run),
      "source_signal_id" => source.signal_id,
      "source_provenance" => %{
        "call_id" => ctx.tool_call_id,
        "response_id" => current_ai_message_id(run),
        "driver_epoch" => run.epoch
      }
    }
  end

  defp cron_attrs(args, ctx, run) do
    {:ok,
     %{
       "agent_uid" => run.agent_uid,
       "owner_session_id" => run.session_id,
       "binding_name" => ctx.binding_name,
       "name" => args["name"],
       "schedule" => args["schedule"],
       "payload" => args["payload"],
       "delivery" => ctx.delivery,
       "idempotency_key" => ctx.idempotency_key,
       "automation_job_id" => args["automation_job_id"]
     }}
  end

  defp turn_created_by(turn) do
    %{
      "kind" => "turn",
      "signal_id" => turn.signal_id,
      "origin_ai_message_id" => current_ai_message_id(turn),
      "driver_epoch" => turn.epoch
    }
  end

  defp checkback_belongs_to_turn(event, %{} = turn_ref) do
    case event.kind == "check_back_later" and event.agent_uid == turn_ref.agent_uid and
           event.session_id == turn_ref.session_id do
      true -> :ok
      false -> {:error, :checkback_not_in_turn}
    end
  end

  defp cron_origin_schedule_id(%{} = turn_ref),
    do: Schedule.cron_execution_schedule_id(turn_ref.session_id)

  defp current_ai_message_id(%{} = turn_ref) do
    if(turn_ref.model_response, do: turn_ref.model_response.id)
  end

  defp schedule_status(:scheduled), do: "scheduled"
  defp schedule_status(:already_scheduled), do: "already_scheduled"

  defp checkback_quiet_success(event) do
    is_map(event.wake_payload) and Map.get(event.wake_payload, "quiet_success") == true
  end

  defp checkback_update_status(:updated), do: "updated"

  defp cron_create_status(:created), do: "created"
  defp cron_create_status(:already_exists), do: "already_exists"

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil
end
