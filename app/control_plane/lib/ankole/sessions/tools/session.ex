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
                  "description": "Ask the user one question only when the answer is necessary to choose the intended result or next action.\nUse the request and prior conversation before asking. Do not ask about a preference the user already gave or when a safe low-risk default is available.\nFor post-task feedback, ask only when the answer will decide whether to accept, revise, or continue the work.\nOn success it returns the normalized question and choices, records them durably, and ends the current turn. Do not emit another answer or call more tools; the user reply arrives as the next user message.",
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
                        "description": "Two to four materially different choices. Omit this field for an open-ended question. Include a no-action choice when the user may decline the action."
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

  def execute(_run, %{"name" => "clarify"}, args) do
    choices =
      Enum.map(args["choices"] || [], fn
        text when is_binary(text) ->
          %{"label" => text}

        item ->
          if item["description"] == item["label"], do: Map.delete(item, "description"), else: item
      end)

    {:ok,
     Tools.result(
       %{"tool" => "clarify", "ok" => true, "question" => args["question"], "choices" => choices},
       terminate: true
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
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> {:ok, at}
      {:error, _} -> {:error, "since and until must be RFC 3339 times"}
    end
  end

  defp trim(text) when is_binary(text), do: String.trim(text)
  defp trim(value), do: value
end
