defmodule Ankole.Conversations.Presentation do
  @behaviour Ankole.Conversations.Tool
  @moduledoc "Publishes driver activity and commits the existing channel reply projection."

  alias Ankole.SignalsGateway.{AIReplyPreview, ActorEvent, Outbox, ReplyInteractions, Projection}
  alias Ankole.Schedule.Delivery
  alias Ankole.Logging

  @activity_keys %{
    "check_back_later" => "schedule_follow_up",
    "cron" => "schedule_follow_up",
    "create_background_job" => "background_job_create",
    "respawn_background_job" => "background_job_respawn",
    "list_background_jobs" => "background_job_list",
    "show_background_job_details" => "background_job_show",
    "send_message_to_background_job" => "background_job_send",
    "stop_background_job" => "background_job_stop",
    "workflow" => "workflow_create",
    "list_workflows" => "workflow_list",
    "show_workflow" => "workflow_show",
    "cancel_workflow" => "workflow_cancel",
    "send_message_to_workflow_task" => "workflow_task_message",
    "sleep" => "workflow_task_sleep",
    "submit_result" => "submit_result",
    "skill_view" => "skill_load",
    "web_search" => "web_search",
    "web_fetch" => "web_fetch",
    "reply_attachment" => "attachment_prepare",
    "send_message" => "processing",
    "clarify" => "clarify",
    "set_channel_standing_orders" => "standing_orders_update"
  }

  @impl true
  def normalize(_name, args), do: args

  @impl true
  def declarations do
    [
      %{
        "type" => "function",
        "name" => "reply_attachment",
        "description" =>
          "Queue a drive file for native delivery with the final reply. Save local files with ankole-files put first. A file under chats/<channel>/ can only be delivered to that channel. Success records the file for delivery; it does not confirm that the provider received it.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "drive_path" => %{
              "type" => "string",
              "minLength" => 1,
              "description" => "File in the drive to deliver."
            },
            "name" => %{
              "type" => "string",
              "minLength" => 1,
              "description" => "Display filename."
            },
            "mimeType" => %{"type" => "string", "minLength" => 1, "description" => "MIME type."}
          },
          "required" => ["drive_path"],
          "additionalProperties" => false
        },
        "execution_mode" => "sequential",
        "read_only" => false,
        "destructive" => false,
        "retry_safe" => false
      }
    ]
  end

  def start(run, driver) do
    with {:ok, :linked} <-
           Ankole.Repo.transact(fn repo ->
             with :ok <- Ankole.Conversations.Fence.check_in_tx(repo, run, :share),
                  :ok <-
                    Projection.link_payload_attachments(
                      run.agent_uid,
                      run.delivered_event.payload,
                      run.delivered_event.signal_channel_id
                    ),
                  do: {:ok, :linked}
           end) do
      with :ok <-
             AIReplyPreview.maybe_start_for(run.event, run.agent_uid, run.conversation.id,
               driver: driver,
               run: run
             ) do
        events =
          Ankole.Conversations.Run.open_events(run)
          |> Enum.filter(&(&1.id in run.steer_event_ids))

        continue(run, events)
      end
    end
  end

  def reply_event(events, fallback) do
    events
    |> Enum.filter(&AIReplyPreview.channel_reply_eligible?/1)
    |> List.last()
    |> then(&(&1 || fallback))
  end

  def continue(run, events) do
    owner = reply_event(events, run.event)

    if owner.id != run.actor_event_id and AIReplyPreview.channel_reply_eligible?(owner),
      do: AIReplyPreview.continue_on(run.actor_event_id, owner),
      else: :ok
  end

  def event(run, kind, payload) do
    payload = activity_payload(payload)
    AIReplyPreview.presentation_event(run.event, %{"kind" => kind, "payload" => payload})
  end

  def activity(run, call, tool, args, phase, result \\ nil) do
    {key, bindings} = activity_description(call["name"], args, phase, result)

    if key do
      event(run, "tool.activity", %{
        "operation_id" => Ankole.Conversations.Run.call_id(call),
        "phase" => phase,
        "label_key" => "signals_gateway.reply.activity.#{key}",
        "label_bindings" => bindings,
        "consequential" => tool.destructive == true
      })
    end
  end

  def waiting(run, call, %{kind: :job} = wait) do
    event(run, "tool.activity", %{
      "operation_id" => Ankole.Conversations.Run.call_id(call),
      "phase" => "running",
      "label_key" => "signals_gateway.reply.activity.background_job_wait",
      "label_bindings" => %{"job" => wait.job_id, "seconds" => wait.timeout_ms / 1000}
    })
  end

  def waiting(_run, _call, _wait), do: :ok

  defp activity_description("web_search", args, _phase, _result),
    do: {"web_search", %{"query" => activity_excerpt(args["query"], 48)}}

  defp activity_description("web_fetch", args, _phase, result) do
    urls = args["urls"] || []
    pages = if result && is_map(result.details), do: result.details["results"] || [], else: []
    page = Enum.find(pages, &is_binary(&1["title"])) || List.first(pages) || %{}
    host = URI.parse(page["url"] || List.first(urls) || "").host
    title = if is_binary(page["title"]), do: "《#{activity_excerpt(page["title"], 40)}》"
    target = [title, host] |> Enum.reject(&is_nil/1) |> Enum.join(" · ")
    key = if length(urls) == 1, do: "web_fetch", else: "web_fetch_many"

    {key <> if(target == "", do: "", else: "_target"),
     %{"target" => target, "count" => length(urls)}}
  end

  defp activity_description("send_message_to_background_job", args, "completed", result) do
    key =
      case result.details do
        %{"wait_outcome" => "timed_out"} -> "background_job_async"
        %{"wait_outcome" => "steered"} -> "background_job_steered"
        %{"wait_outcome" => _outcome} -> "background_job_replied"
        _ -> if(args["wait_reply"], do: "background_job_replied", else: "background_job_sent")
      end

    {key, %{}}
  end

  defp activity_description(name, args, _phase, _result),
    do: {@activity_keys[name], Map.take(args, ["name"])}

  defp activity_excerpt(nil, _limit), do: ""

  defp activity_excerpt(text, limit) do
    text = text |> String.replace(~r/[\x00-\x1f\x7f\s]+/u, " ") |> String.trim()
    chars = String.codepoints(text)

    if length(chars) > limit,
      do: Enum.take(chars, limit - 1) |> Enum.join() |> Kernel.<>("…"),
      else: text
  end

  defp activity_payload(%{"activity" => activity} = payload) when is_map(activity) do
    payload
    |> Map.delete("activity")
    |> Map.put("label_key", activity["key"])
    |> Map.put("label_bindings", activity["bindings"] || %{})
  end

  defp activity_payload(%{"activity" => activity} = payload) when is_binary(activity),
    do: payload |> Map.delete("activity") |> Map.put("label", activity)

  defp activity_payload(payload), do: payload

  def stop(run), do: AIReplyPreview.stop(run.event)

  @impl true
  def execute_in_tx(_repo, run, %{"name" => "reply_attachment"}, args) do
    with {:ok, file} <- Ankole.Files.fetch(run.agent_uid, args["drive_path"]),
         :ok <- Ankole.Files.verify_delivery(file.path, run.event.signal_channel_id),
         digest = Base.encode16(file.sha256, case: :lower),
         name = args["name"] || Path.basename(file.path) do
      details = %{
        "tool" => "reply_attachment",
        "ok" => true,
        "delivery_state" => "queued",
        "attachments" => [
          %{
            "path" => file.path,
            "blob_ref" => digest,
            "name" => name,
            "mime_type" => args["mimeType"] || file.content_type,
            "size" => file.size
          }
        ]
      }

      {:ok, Ankole.Conversations.Tools.result(details), []}
    end
  end

  def commit_outboxes_in_tx(_repo, _event, _completion, "silent", _now), do: {:ok, no_outboxes()}

  def commit_outboxes_in_tx(repo, event, completion, outcome, now) do
    if AIReplyPreview.channel_reply_eligible?(event) do
      case commit_reply_outboxes(repo, event, completion, outcome, now) do
        {:ok, outboxes} -> {:ok, outboxes}
        {:error, reason} -> skip_unroutable_reply(event, reason)
      end
    else
      {:ok, no_outboxes()}
    end
  end

  # The channel accepts no replies, or its route rows are deleted. The Turn's
  # work already happened and its answer is already in the transcript, so the
  # Turn completes and no impossible provider intent is stored. Failing here
  # would retry the whole Turn, and every retry costs another model call while
  # the route stays exactly as unreachable.
  #
  # A single default reply checks its one route before any outbox row is written,
  # so it reaches this branch. A cron target resolves its own route too, but
  # records an unreachable one as a terminal `:unsupported` row instead, because
  # one unavailable target must not cancel the others.
  defp skip_unroutable_reply(%ActorEvent{} = event, reason) do
    if Outbox.unroutable_reply_reason?(reason) do
      Logging.warning(
        "signals_gateway.actor_turn_completion.reply_route_unroutable",
        "actor turn completed without a reachable reply route",
        %{
          actor_event_id: event.id,
          agent_uid: event.agent_uid,
          binding_name: event.binding_name,
          signal_channel_id: event.signal_channel_id,
          reason: inspect(reason, limit: 20)
        }
      )

      {:ok, no_outboxes()}
    else
      {:error, reason}
    end
  end

  defp no_outboxes, do: %{attachments: [], clarify: nil, finals: []}

  defp commit_reply_outboxes(repo, event, completion, outcome, now) do
    opts = [turn_completion_outcome: outcome, delivery_targets: delivery_targets(event)]

    with {:ok, attachments} <-
           Outbox.commit_reply_attachment_outboxes_in_tx(
             repo,
             event,
             completion.final_response.id,
             completion.attachments,
             opts
           ),
         {:ok, clarify} <- commit_clarify_outbox(repo, event, completion, opts, now),
         {:ok, finals} <- commit_final_outboxes(repo, event, completion, opts) do
      {:ok, %{attachments: attachments, clarify: clarify, finals: finals}}
    end
  end

  defp commit_clarify_outbox(_repo, _event, %{clarify_prompt: nil}, _opts, _now),
    do: {:ok, nil}

  defp commit_clarify_outbox(repo, event, completion, opts, now) do
    if AIReplyPreview.channel_reply_eligible?(event) do
      %{"fallback_visible_text" => fallback, "interactive_output" => interactive_output} =
        completion.clarify_prompt

      text = join_clarify_text(completion.final_text, fallback)

      with {:ok, outbox} <-
             Outbox.commit_clarify_reply_outbox_in_tx(
               repo,
               event,
               completion.final_response,
               text,
               interactive_output,
               opts
             ),
           {:ok, _event} <-
             ReplyInteractions.open_in_tx(
               repo,
               event,
               outbox.payload["reply_presentation"],
               now
             ) do
        {:ok, outbox}
      end
    else
      {:ok, nil}
    end
  end

  defp commit_final_outboxes(repo, event, completion, opts) do
    if AIReplyPreview.channel_reply_eligible?(event) and is_nil(completion.clarify_prompt) and
         is_binary(completion.final_text) do
      Outbox.commit_final_reply_outboxes_in_tx(
        repo,
        event,
        completion.final_response,
        completion.final_text,
        Keyword.put(opts, :attachment_count, length(completion.attachments))
      )
    else
      {:ok, []}
    end
  end

  defp delivery_targets(%ActorEvent{} = event) do
    case ActorEvent.scheduled_delivery_snapshot(event) do
      %{} = delivery -> normalized_delivery_targets(event, delivery)
      _missing -> [default_delivery_target(event)]
    end
  end

  defp normalized_delivery_targets(event, delivery) do
    case Delivery.targets(delivery, event.binding_name) do
      {:ok, targets} ->
        targets
        |> Enum.with_index()
        |> Enum.map(fn {target, index} ->
          %{
            binding_name: target["binding_name"],
            signal_channel_id: target["signal_channel_id"],
            provider_thread_id: target["provider_thread_id"],
            primary: index == 0,
            key: Delivery.target_key(target)
          }
        end)

      {:error, reason} ->
        Logging.warning(
          "signals_gateway.actor_turn_completion.scheduled_delivery_invalid",
          "scheduled work completed with an invalid delivery snapshot",
          %{
            actor_event_id: event.id,
            agent_uid: event.agent_uid,
            actor_event_type: event.type,
            reason: inspect(reason, limit: 20)
          }
        )

        [default_delivery_target(event)]
    end
  end

  defp default_delivery_target(event) do
    %{
      binding_name: event.binding_name,
      signal_channel_id: event.signal_channel_id,
      provider_thread_id: event.provider_thread_id,
      primary: true,
      key: nil
    }
  end

  defp join_clarify_text(nil, fallback), do: fallback
  defp join_clarify_text("", fallback), do: fallback
  defp join_clarify_text(text, fallback), do: text <> "\n\n" <> fallback
end
