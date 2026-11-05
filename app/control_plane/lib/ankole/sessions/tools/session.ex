defmodule Ankole.Sessions.Tools.Session do
  @behaviour Ankole.Sessions.Tool
  @moduledoc false
  @declarations Ankole.JSON.decode!(~S"""
                [
                {
                  "type": "function",
                  "name": "todo",
                  "receipt": "none",
                  "description": "Manage your task list for the current session. Use for complex tasks with 3+ steps or when the user provides multiple tasks.\nList order is priority. Only ONE item in_progress at a time.\nMark items completed immediately when done. If something fails, cancel it and add a revised item.\nAlways returns the full current list.",
                  "parameters": {
                    "type": "object",
                    "properties": {
                      "todos": {
                        "maxItems": 256,
                        "type": "array",
                        "items": {
                          "type": "object",
                          "properties": {
                            "id": {
                              "type": "string",
                              "minLength": 1,
                              "description": "Unique item identifier."
                            },
                            "content": {
                              "type": "string",
                              "minLength": 1,
                              "maxLength": 4000,
                              "description": "Task description."
                            },
                            "status": {
                              "type": "string",
                              "enum": [
                                "pending",
                                "in_progress",
                                "completed",
                                "cancelled"
                              ],
                              "description": "Current status."
                            }
                          },
                          "required": [
                            "id",
                            "content",
                            "status"
                          ],
                          "additionalProperties": false
                        },
                        "description": "Task items to write. Omit to read current list."
                      },
                      "merge": {
                        "type": "boolean",
                        "description": "true: update existing items by id and add new ones. false: replace the entire list.",
                        "default": false
                      }
                    },
                    "additionalProperties": false
                  },
                  "execution_mode": "sequential",
                  "read_only": false,
                  "destructive": false
                },
                {
                  "type": "function",
                  "name": "clarify",
                  "activity": "clarify",
                  "receipt": "none",
                  "visible_delivery": true,
                  "description": "Ask the user one question only when the answer is necessary to choose the intended result or next action.\nUse the request and prior conversation before asking. Do not ask about a preference the user already gave or when a safe low-risk default is available.\nFor post-task feedback, ask only when the answer will decide whether to accept, revise, or continue the work.\nWhen the answer needs several typed values, pass fields instead of choices; keep forms to the few values you cannot proceed without.\nOn success it returns the normalized question, choices, and fields, records them durably, and ends the current turn. Do not emit another answer or call more tools; the user reply arrives as the next user message.",
                  "parameters": {
                    "type": "object",
                    "properties": {
                      "question": {
                        "type": "string",
                        "minLength": 1,
                        "maxLength": 2000,
                        "description": "One self-contained question with only the context needed to answer it."
                      },
                      "choices": {
                        "minItems": 2,
                        "maxItems": 4,
                        "type": "array",
                        "items": {
                          "anyOf": [
                            {
                              "type": "string",
                              "minLength": 1,
                              "maxLength": 200,
                              "description": "A short label that identifies the choice without rereading the question."
                            },
                            {
                              "type": "object",
                              "properties": {
                                "label": {
                                  "type": "string",
                                  "minLength": 1,
                                  "maxLength": 200,
                                  "description": "A short label that identifies the choice without rereading the question."
                                },
                                "description": {
                                  "description": "The result or tradeoff of selecting this choice.",
                                  "type": "string",
                                  "minLength": 1,
                                  "maxLength": 500
                                }
                              },
                              "required": [
                                "label"
                              ],
                              "additionalProperties": false
                            }
                          ]
                        },
                        "description": "Two to four materially different choices. Omit this field for an open-ended question or a form. Include a no-action choice when the user may decline the action."
                      },
                      "fields": {
                        "minItems": 1,
                        "maxItems": 5,
                        "type": "array",
                        "description": "A short form for answers that need several typed values (for example a quantity, a date, and destinations). Omit it for one choice or an open question; a form does not take choices and needs at least one required field. The user can still answer in their own words instead.",
                        "items": {
                          "type": "object",
                          "properties": {
                            "id": {
                              "type": "string",
                              "pattern": "^[a-z][a-z0-9_]{0,39}$",
                              "description": "Unique snake_case key of the value in the answer."
                            },
                            "label": {
                              "type": "string",
                              "minLength": 1,
                              "maxLength": 80
                            },
                            "help": {
                              "type": "string",
                              "maxLength": 200,
                              "description": "Optional hint shown under the field."
                            },
                            "type": {
                              "type": "string",
                              "enum": ["text", "number", "date", "select", "multi_select", "boolean"]
                            },
                            "required": {
                              "type": "boolean",
                              "description": "Defaults to true."
                            },
                            "default": {
                              "description": "Optional prefilled value valid for the field: a string, number, YYYY-MM-DD date, option value, list of option values, or boolean."
                            },
                            "max_length": {
                              "type": "integer",
                              "minimum": 1,
                              "maximum": 1000,
                              "description": "text only. Defaults to 200."
                            },
                            "multiline": {
                              "type": "boolean",
                              "description": "text only."
                            },
                            "integer": {
                              "type": "boolean",
                              "description": "number only: accept whole numbers only."
                            },
                            "min": {
                              "type": ["number", "string"],
                              "description": "number: lowest value. date: earliest YYYY-MM-DD date."
                            },
                            "max": {
                              "type": ["number", "string"],
                              "description": "number: highest value. date: latest YYYY-MM-DD date."
                            },
                            "unit": {
                              "type": "string",
                              "maxLength": 20,
                              "description": "number only: unit label such as kg or USD."
                            },
                            "options": {
                              "type": "array",
                              "minItems": 2,
                              "maxItems": 10,
                              "description": "select and multi_select only. The answer uses option values.",
                              "items": {
                                "type": "object",
                                "properties": {
                                  "value": {"type": "string", "minLength": 1, "maxLength": 100},
                                  "label": {"type": "string", "minLength": 1, "maxLength": 80}
                                },
                                "required": ["value", "label"],
                                "additionalProperties": false
                              }
                            },
                            "min_items": {
                              "type": "integer",
                              "minimum": 0,
                              "description": "multi_select only."
                            },
                            "max_items": {
                              "type": "integer",
                              "minimum": 1,
                              "description": "multi_select only."
                            }
                          },
                          "required": ["id", "label", "type"],
                          "additionalProperties": false
                        }
                      }
                    },
                    "required": [
                      "question"
                    ],
                    "additionalProperties": false
                  },
                  "execution_mode": "sequential",
                  "read_only": false,
                  "destructive": false
                },
                {
                  "type": "function",
                  "name": "set_channel_standing_orders",
                  "activity": "standing_orders_update",
                  "description": "Replace the standing orders of the current channel: a short durable policy for when you should proactively speak here without being addressed (for example \"only speak up when CI turns red\" or \"post a daily summary at 18:00\").\nUse this tool when a channel member tells you how to behave in this channel going forward. Any member may set or clear them; the platform records who asked.\nStanding orders drive behavior when you may intervene in a native group room or the channel binding permits ambient intervention; the tool result reports whether they are active.\nThe current standing orders, when present, appear in your conversation context. Writing is a full replacement: to amend, submit the complete new text.\nAfter a confirmed save, summarize the stored orders in your visible reply.",
                  "parameters": {
                    "type": "object",
                    "properties": {
                      "orders": {
                        "type": "string",
                        "maxLength": 4000,
                        "description": "Full replacement text of the standing orders for this channel. An empty string clears them."
                      }
                    },
                    "required": [
                      "orders"
                    ],
                    "additionalProperties": false
                  },
                  "execution_mode": "sequential",
                  "read_only": false,
                  "destructive": false
                },
                {
                  "type": "function",
                  "name": "read_channel_history",
                  "description": "Read earlier messages of the current channel, oldest first. Use it when a request needs more of the discussion than your context shows, for example a weekly summary, a todo list from a discussion, or what was decided earlier.\nThe history holds messages of the shared conversation, including messages recorded by other Agent bindings and your own replies. Narrow it with since and until (RFC 3339 time) and with query (a case-insensitive text match). Each result is one page; pass its next_page as page to read on.",
                  "parameters": {
                    "type": "object",
                    "properties": {
                      "since": {
                        "type": "string",
                        "format": "date-time",
                        "description": "Only messages sent at or after this time."
                      },
                      "until": {
                        "type": "string",
                        "format": "date-time",
                        "description": "Only messages sent at or before this time."
                      },
                      "query": {
                        "type": "string",
                        "minLength": 1,
                        "maxLength": 200,
                        "description": "Only messages whose text contains this text."
                      },
                      "page": {
                        "type": "string",
                        "description": "next_page from an earlier result in this turn."
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
                  "name": "propose_action_card",
                  "activity": "action_card_prepare",
                  "receipt": "none",
                  "visible_delivery": true,
                  "description": "Draft a privilege-escalated Action Card when you lack permission to perform a sensitive workspace operation directly (such as creating Brain objects (brain.object.create) or saving shared knowledge (pod.knowledge.save), both in native Pod rooms only, updating page/file sharing, moving a page/file to trash, restoring from trash, deleting a Base table, or adding participants to a Pod native room).\nThe card snapshots current CAS preconditions and renders Confirm & Execute / Cancel controls so an authorized human can execute it with their own permissions.\nOn success it records the prepared card and ends the current turn; when an authorized human confirms it, you receive an [Action Card Executed] wakeup.",
                  "parameters": {
                    "type": "object",
                    "properties": {
                      "action_kind": {
                        "type": "string",
                        "enum": [
                          "pod.knowledge.save",
                          "brain.object.create",
                          "pod.page.set_sharing",
                          "pod.page.delete",
                          "pod.page.restore",
                          "pod.base.delete_table",
                          "conversation.add_participants"
                        ],
                        "description": "Closed action kind to propose."
                      },
                      "category": {"type": "string", "description": "Installed Brain ontology category for brain.object.create."},
                      "title": {"type": "string", "description": "Title for a new Brain object."},
                      "base_revision": {"type": "integer", "minimum": 0, "description": "Revision read before drafting pod.knowledge.save."},
                      "markdown": {"type": "string", "description": "Complete proposed OKF Markdown and frontmatter for pod.knowledge.save or brain.object.create."},
                      "summary": {
                        "type": "string",
                        "minLength": 1,
                        "maxLength": 500,
                        "description": "Concise human-readable explanation of what will change and why."
                      },
                      "node_id": {
                        "type": "string",
                        "description": "Target Drive/Pod node UUID (required for pod.page.set_sharing, pod.page.delete, pod.page.restore)."
                      },
                      "page_id": {
                        "type": "string",
                        "description": "Optional owning Base page UUID for pod.base.delete_table."
                      },
                      "table_id": {
                        "type": "string",
                        "description": "Target Base table UUID (required for pod.base.delete_table)."
                      },
                      "inherit_permissions": {
                        "type": "boolean",
                        "description": "Whether the node inherits parent permissions (optional for pod.page.set_sharing)."
                      },
                      "grants": {
                        "type": "array",
                        "description": "Full replacement grant list for pod.page.set_sharing.",
                        "items": {
                          "type": "object",
                          "properties": {
                            "principal_uid": {
                              "type": "string"
                            },
                            "group_id": {
                              "type": "string"
                            },
                            "role": {
                              "type": "string",
                              "enum": ["view", "contribute", "edit", "manage"]
                            },
                            "target_scope": {
                              "type": "string",
                              "enum": ["container", "self"]
                            }
                          },
                          "required": ["role"],
                          "additionalProperties": false
                        }
                      },
                      "participant_uids": {
                        "type": "array",
                        "description": "Principal UIDs to add to the current Pod native room (required for conversation.add_participants; rejected on external IM channels).",
                        "items": {
                          "type": "string",
                          "minLength": 1
                        }
                      }
                    },
                    "required": [
                      "action_kind",
                      "summary"
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
  def declarations, do: @declarations
  @impl true
  def declarations(run) do
    Enum.reject(@declarations, fn tool ->
      case tool["name"] do
        "read_channel_history" -> is_nil(run.event.conversation_id)
        "propose_action_card" -> is_nil(run.event.conversation_id)
        "set_channel_standing_orders" -> not standing_orders_available?(run.event)
        _ -> false
      end
    end)
  end

  defp standing_orders_available?(%{reply_binding_name: name}) when is_binary(name), do: true

  defp standing_orders_available?(%{conversation_id: id}) when is_binary(id) do
    match?(
      %{kind: :native, room_mode: :group},
      Ankole.Conversations.get_conversation!(id)
    )
  end

  defp standing_orders_available?(_), do: false

  alias Ankole.Sessions.Run
  alias Ankole.Sessions.Tools

  @impl true
  def normalize("todo", args) when is_map(args) do
    if is_list(args["todos"]),
      do:
        Map.update!(
          args,
          "todos",
          &Enum.map(&1, fn
            item when is_map(item) ->
              item
              |> Map.replace_lazy("id", fn text ->
                if is_binary(text), do: String.trim(text), else: text
              end)
              |> Map.replace_lazy("content", fn text ->
                if is_binary(text), do: String.trim(text), else: text
              end)

            item ->
              item
          end)
        ),
      else: args
  end

  def normalize("clarify", args) when is_map(args) do
    args = Map.update(args, "question", nil, &trim/1)

    if is_list(args["choices"]),
      do:
        Map.update!(
          args,
          "choices",
          &Enum.map(&1, fn
            text when is_binary(text) -> String.trim(text)
            %{} = item -> Map.new(item, fn {k, v} -> {k, trim(v)} end)
            other -> other
          end)
        ),
      else: args
  end

  def normalize("propose_action_card", args) when is_map(args) do
    Map.update(args, "summary", nil, &trim/1)
  end

  def normalize(_name, args), do: args

  @impl true
  def execute(run, %{"name" => "todo"} = call, args) do
    old = if is_list(run.todo), do: run.todo, else: []

    items =
      case args["todos"] do
        nil -> old
        incoming -> merge(if(args["merge"], do: old, else: []), incoming)
      end

    summary =
      Enum.reduce(items, Map.new(~w(pending in_progress completed cancelled), &{&1, 0}), fn item,
                                                                                            totals ->
        Map.update!(totals, item["status"], &(&1 + 1))
      end)
      |> Map.put("total", length(items))

    {:ok,
     Tools.result(%{"todos" => items, "summary" => summary},
       todos: items,
       presentation: [
         %{
           "kind" => "plan.snapshot",
           "payload" => %{"operation_id" => Run.call_id(call), "items" => items}
         }
       ]
     )}
  end

  def execute(run, %{"name" => "read_channel_history"}, args) do
    with {:ok, cursor} <- Tools.cursor(run, "channel_history", args["page"]),
         {:ok, since} <- time(args["since"]),
         {:ok, until} <- time(args["until"]) do
      page =
        Ankole.Conversations.Context.history_page(run.event.conversation_id,
          since: since,
          until: until,
          query: args["query"],
          cursor: cursor
        )

      {:ok,
       Tools.result(%{"messages" => page.messages},
         cursor: {"channel_history", page.next_cursor}
       )}
    end
  end

  def execute(_run, %{"name" => "clarify"} = call, args) do
    choices =
      Enum.map(args["choices"] || [], fn
        text when is_binary(text) ->
          %{"label" => text}

        item ->
          if item["description"] == item["label"], do: Map.delete(item, "description"), else: item
      end)

    with {:ok, fields} <- clarify_fields(args["fields"], choices),
         output =
           Ankole.Attrs.maybe_put(
             %{
               "tool" => "clarify",
               "ok" => true,
               "question" => args["question"],
               "choices" => choices
             },
             "fields",
             if(fields != [], do: fields)
           ),
         {:ok, prompt} <-
           Ankole.Conversations.Delivery.ClarifyPrompt.from_output(output, Run.call_id(call)) do
      {:ok,
       Tools.result(output,
         terminate: true,
         interaction: %{"kind" => "clarify", "prompt" => prompt}
       )}
    else
      {:invalid_arguments, message} ->
        {:ok, Tools.error("Invalid arguments for tool clarify: #{message}", "invalid_arguments")}

      {:error, _reason} = error ->
        error
    end
  end

  def execute(run, %{"name" => "propose_action_card"} = call, args) do
    with {:ok, draft} <- Ankole.Conversations.ActionCards.prepare_draft(run, call, args),
         {:ok, prompt} <-
           Ankole.Conversations.Delivery.ActionCardPrompt.from_output(draft, Run.call_id(call)),
         do:
           {:ok,
            Tools.result(draft,
              terminate: true,
              interaction: %{"kind" => "action_card", "prompt" => prompt}
            )}
  end

  @impl true
  def prepare_in_tx(run, call, args),
    do: {:ok, [], fn -> commit_tool_in_tx(run, call, args) end}

  defp commit_tool_in_tx(run, %{"name" => "set_channel_standing_orders"}, args) do
    with {:ok, saved} <-
           Ankole.Sessions.AmbientCuration.set_standing_orders_in_tx(
             run.agent_uid,
             run.signal_id,
             args["orders"],
             DateTime.utc_now(:microsecond)
           ) do
      {:ok,
       Tools.result(%{
         "status" => "ok",
         "orders" => saved.orders,
         "set_by" => saved.set_by,
         "active" => saved.active
       }), []}
    end
  end

  defp merge(old, incoming) do
    {ids, items} =
      Enum.reduce(
        incoming,
        {Enum.map(Enum.reverse(old), & &1["id"]), Map.new(old, &{&1["id"], &1})},
        fn item, {ids, items} ->
          id = item["id"]
          {if(Map.has_key?(items, id), do: ids, else: [id | ids]), Map.put(items, id, item)}
        end
      )

    ids |> Enum.reverse() |> Enum.take(256) |> Enum.map(&Map.fetch!(items, &1))
  end

  defp time(nil), do: {:ok, nil}

  defp time(text) do
    case Ankole.Attrs.parse_datetime(text) do
      %DateTime{} = at -> {:ok, at}
      nil -> {:error, "since and until must be RFC 3339 times"}
    end
  end

  defp clarify_fields(nil, _choices), do: {:ok, []}

  defp clarify_fields(_fields, [_ | _]),
    do: {:invalid_arguments, "a form clarify takes fields or choices, not both"}

  defp clarify_fields(fields, []) do
    case Ankole.Conversations.Delivery.ClarifyForm.definition(fields) do
      {:ok, fields} -> {:ok, fields}
      {:error, message} -> {:invalid_arguments, message}
    end
  end

  defp trim(text) when is_binary(text), do: String.trim(text)
  defp trim(value), do: value
end
