defmodule Ankole.Sessions.Presentation do
  @behaviour Ankole.Sessions.Tool
  @moduledoc "Publishes Driver activity and commits native statements or external Delivery intents."

  alias Ankole.Conversations.Target, as: StatementTarget
  alias Ankole.Conversations.Delivery.Preview
  alias Ankole.Sessions.Queue
  alias Ankole.Signals.Signal
  alias Ankole.Conversations.Delivery
  alias Ankole.Conversations.Attachments
  alias Ankole.Schedule.Delivery, as: ScheduledDelivery
  alias Ankole.AIGateway.Artifacts
  alias Ankole.AIGateway.Schemas.Artifact
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.Sessions.ModelHistory
  alias Ankole.Conversations.Delivery.{Text, ClarifyPrompt, Attachment}
  alias Ankole.Files
  alias Ankole.Logging

  @impl true
  def normalize(_name, args), do: args

  @impl true
  def declarations do
    [
      %{
        "type" => "function",
        "name" => "reply_attachment",
        "activity" => "attachment_prepare",
        "visible_delivery" => true,
        "description" =>
          "Queue a drive file for provider delivery with the final reply. Save local files with ankole-files put first. A file under chats/<conversation_id>/ can only be delivered to that conversation. Success records the file for delivery; it does not confirm that the provider received it.",
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
           Ankole.Repo.transact_top_level(fn -> link_input_in_tx(run) end)
           |> Ankole.Errors.reason() do
      with :ok <-
             Preview.maybe_start_for(run.event, run.agent_uid, run.conversation.id,
               driver: driver,
               run: run
             ) do
        events =
          Ankole.Sessions.Queue.due(run)
          |> Enum.filter(&(&1.id in run.steer_event_ids))

        continue(run, events)
      end
    end
  end

  @doc false
  def link_input_in_tx(run) do
    with :ok <- Ankole.Sessions.Fence.check_in_tx(run, :share),
         :ok <-
           Attachments.link_payload_in_tx(
             run.agent_uid,
             Signal.envelope(run.delivered_event),
             run.delivered_event.conversation_id
           ),
         do: {:ok, :linked}
  end

  def reply_event(events, fallback) do
    events
    |> Enum.filter(fn event ->
      case StatementTarget.for_reply(event) do
        {:ok, target} -> StatementTarget.reply_eligible?(target, event)
        _ -> false
      end
    end)
    |> List.last()
    |> then(&(&1 || fallback))
  end

  def continue(run, events) do
    owner = reply_event(events, run.event)

    if owner.id != run.signal_id and Preview.channel_reply_eligible?(owner),
      do: Preview.continue_on(run.signal_id, owner),
      else: :ok
  end

  def event(run, kind, payload) do
    event = %{"kind" => kind, "payload" => activity_payload(payload)}
    Preview.presentation_event(run.event, event)
    event
  end

  def tool_activity(call, tool, args, phase, result \\ nil) do
    {key, bindings} =
      if tool.executor != :worker and function_exported?(tool.executor, :activity, 4),
        do: tool.executor.activity(tool, args, phase, result),
        else: {tool.activity, Map.take(args, ["name"])}

    if key do
      [
        %{
          "kind" => "tool.activity",
          "payload" => %{
            "operation_id" => Ankole.Sessions.Run.call_id(call),
            "phase" => phase,
            "label_key" => "conversations.delivery.reply.activity.#{key}",
            "label_bindings" => bindings,
            "consequential" => tool.destructive == true
          }
        }
      ]
    else
      []
    end
  end

  def waiting(call, %{kind: :job} = wait) do
    [
      %{
        "kind" => "tool.activity",
        "payload" => %{
          "operation_id" => Ankole.Sessions.Run.call_id(call),
          "phase" => "running",
          "label_key" => "conversations.delivery.reply.activity.background_job_wait",
          "label_bindings" => %{"job" => wait.job_id, "seconds" => wait.timeout_ms / 1000}
        }
      }
    ]
  end

  def waiting(_call, _wait), do: []

  def activity_excerpt(nil, _limit), do: ""

  def activity_excerpt(text, limit) do
    text = text |> String.replace(~r/[\x00-\x1f\x7f\s]+/u, " ") |> String.trim()
    chars = String.codepoints(text)

    if length(chars) > limit,
      do: Enum.take(chars, limit - 1) |> Enum.join() |> Kernel.<>("…"),
      else: text
  end

  defp activity_payload(%{"activity" => activity} = payload) when is_map(activity) do
    payload
    |> Map.delete("activity")
    |> Map.put("label_key", current_activity_key(activity["key"]))
    |> Map.put("label_bindings", activity["bindings"] || %{})
  end

  defp activity_payload(%{"activity" => activity} = payload) when is_binary(activity),
    do: payload |> Map.delete("activity") |> Map.put("label", activity)

  defp activity_payload(payload), do: payload

  def publish_committed(%Ankole.Sessions.Run{event: event}),
    do: Ankole.Sessions.Events.publish_status(event.agent_uid, event.session_id)

  def publish_committed(%{signal: event} = result) do
    Enum.each(
      Map.get(result, :posted, %Ankole.Conversations.PostResult{}).messages,
      &Ankole.Conversations.Events.publish_message(&1.conversation_id)
    )

    case result do
      %{status: :completed, outcome: outcome} ->
        Ankole.Sessions.Events.publish_turn_completed(
          event.agent_uid,
          event.session_id,
          event.id,
          outcome
        )

      _ ->
        Ankole.Sessions.Events.publish_status(event.agent_uid, event.session_id)
    end
  end

  def publish_committed(_result), do: :ok

  # Remove after pre-rename Worker images and their open Workspaces retire.
  defp current_activity_key("signals_gateway.reply.activity." <> suffix),
    do: "conversations.delivery.reply.activity." <> suffix

  defp current_activity_key(key), do: key

  def stop(run), do: Preview.stop(run.event)

  @impl true
  def prepare_in_tx(run, call, args),
    do: {:ok, [], fn -> commit_tool_in_tx(run, call, args) end}

  defp commit_tool_in_tx(run, %{"name" => "reply_attachment"}, args) do
    with {:ok, file} <- Ankole.Files.fetch(run.agent_uid, args["drive_path"]),
         :ok <- Ankole.Files.verify_delivery(file.path, run.event.conversation_id),
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

      {:ok, Ankole.Sessions.Tools.result(details), []}
    end
  end

  def targets_in_tx(event) do
    delivery =
      if event.type != "cron.fire" or Ankole.Sessions.Scheduled.produced_signal?(event),
        do: Signal.scheduled_delivery_snapshot(event)

    if is_map(delivery) do
      with {:ok, items} <- ScheduledDelivery.targets(delivery, event.reply_binding_name) do
        items
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, targets} ->
          case StatementTarget.for_delivery_in_tx(
                 event.agent_uid,
                 Map.put(item, "primary", index == 0)
               ) do
            {:ok, target} -> {:cont, {:ok, [target | targets]}}
            {:error, :conversation_not_found} -> {:cont, {:ok, targets}}
            error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, targets} -> {:ok, Enum.reverse(targets)}
          error -> error
        end
      end
    else
      case StatementTarget.for_reply(event) do
        {:ok, target} -> {:ok, [target]}
        {:error, :reply_route_unavailable} -> {:ok, []}
      end
    end
  end

  def post_in_tx(_event, %Ankole.Conversations.Statement{outcome: :silent}),
    do: {:ok, %Ankole.Conversations.PostResult{}}

  def post_in_tx(event, statement) do
    :ok = Queue.lock_session_in_tx(event.agent_uid, event.session_id)

    with {:ok, targets} <- targets_in_tx(event) do
      targets =
        Enum.filter(targets, fn target ->
          statement.notice != nil or StatementTarget.reply_eligible?(target, event)
        end)

      Enum.reduce_while(targets, {:ok, %Ankole.Conversations.PostResult{}}, fn target,
                                                                               {:ok, posted} ->
        case Ankole.Conversations.post_in_tx(target, statement) do
          {:ok, result} ->
            {:cont, {:ok, Ankole.Conversations.PostResult.merge(posted, result)}}

          {:error, reason} ->
            if Delivery.unroutable_reply_reason?(reason) do
              Logging.warning(
                "sessions.turn_completion.reply_route_unroutable",
                "Session turn completed without a reachable reply route",
                %{signal_id: event.id, reason: inspect(reason)}
              )

              {:cont, {:ok, posted}}
            else
              {:halt, {:error, reason}}
            end
        end
      end)
    end
  end

  @doc "Stores generated bytes before the caller takes the final Session transaction."
  def prepare_generated_images(run, final_response_id) do
    Ankole.Repo.assert_outside_transaction!()

    with {:ok, chain} <- ModelHistory.load_turn_chain(run, final_response_id),
         {:ok, image_ids} <- generated_image_ids(chain.response_chain) do
      Enum.reduce_while(image_ids, {:ok, %{}}, fn image_id, {:ok, prepared} ->
        case prepare_generated_image(run.agent_uid, image_id) do
          {:ok, image} -> {:cont, {:ok, Map.put(prepared, image_id, image)}}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp prepare_generated_image(subject_uid, image_id) do
    with {:ok, artifact} <- Artifacts.get_generated_image(subject_uid, image_id, payload?: true),
         {:ok, extension} <- generated_image_extension(image_id, artifact.mime_type),
         {:ok, stored} <- Files.store(artifact.payload) do
      {:ok,
       %{
         artifact_id: artifact.id,
         sha256: stored.sha256,
         size: stored.size,
         mime_type: artifact.mime_type,
         filename: "#{Artifacts.public_id(artifact)}.#{extension}"
       }}
    else
      reason -> generated_image_retry(image_id, reason)
    end
  end

  @doc "Projects the current journal anchor and commits only prepared image references."
  def load_completion_in_tx(run, final_response_id, images) do
    with {:ok, chain} <- ModelHistory.load_turn_chain(run, final_response_id),
         {:ok, projection} <-
           project_completion(
             run.agent_uid,
             chain.response_chain,
             chain.final_response,
             Ankole.Conversations.ExternalTarget.origin(chain.conversation),
             images
           ) do
      {:ok, Map.merge(chain, projection)}
    end
  end

  defp project_completion(subject_uid, turn_chain, final_response, origin, images) do
    source_items =
      turn_chain
      |> Enum.reverse()
      |> Enum.flat_map(&message_items/1)
      |> dedupe_function_call_outputs()

    final_text = Text.visible_text(final_response.content)

    with {:ok, clarify_prompt} <- ClarifyPrompt.from_response_items(source_items),
         {:ok, attachments} <- Attachment.attachments_from_response_items(source_items),
         {:ok, generated_image_attachments} <-
           materialize_generated_images(subject_uid, turn_chain, origin, images),
         attachments = attachments ++ generated_image_attachments do
      {:ok,
       %{
         final_text: final_text,
         clarify_prompt: clarify_prompt,
         attachments: attachments
       }}
    end
  end

  defp message_items(%Message{content: content}) when is_list(content), do: content
  defp message_items(_message), do: []

  defp materialize_generated_images(subject_uid, turn_chain, origin, images) do
    with {:ok, image_ids} <- generated_image_ids(turn_chain) do
      Enum.reduce_while(image_ids, {:ok, []}, fn image_id, {:ok, attachments} ->
        case materialize_generated_image(subject_uid, image_id, origin, images) do
          {:ok, attachment} -> {:cont, {:ok, [attachment | attachments]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, attachments} -> {:ok, Enum.reverse(attachments)}
        {:error, _reason} = error -> error
      end
    end
  end

  defp generated_image_ids(turn_chain) do
    turn_chain
    |> Enum.reverse()
    |> Enum.flat_map(&generated_image_items/1)
    |> Enum.reduce_while({:ok, []}, fn
      %{"id" => image_id}, {:ok, ids} when is_binary(image_id) ->
        {:cont, {:ok, [image_id | ids]}}

      _item, _acc ->
        {:halt, {:error, :invalid_completed_image_generation_call}}
    end)
    |> case do
      {:ok, ids} -> {:ok, ids |> Enum.reverse() |> Enum.uniq()}
      {:error, _reason} = error -> error
    end
  end

  defp generated_image_items(%Message{content: content, metadata: metadata})
       when is_list(content) and is_map(metadata) do
    content
    |> Enum.drop(request_item_count(metadata))
    |> Enum.filter(&completed_generated_image?/1)
  end

  defp generated_image_items(_message), do: []

  defp request_item_count(%{"request_item_count" => count})
       when is_integer(count) and count >= 0,
       do: count

  defp request_item_count(_metadata), do: 0

  defp completed_generated_image?(%{
         "type" => "image_generation_call",
         "status" => "completed"
       }),
       do: true

  defp completed_generated_image?(_item), do: false

  # Retried completions keep the same path in the source channel's directory.
  defp materialize_generated_image(subject_uid, image_id, origin, images) do
    with {:ok, %Artifact{} = artifact} <- Artifacts.get_generated_image(subject_uid, image_id),
         %{artifact_id: id, sha256: sha256, filename: filename, mime_type: mime, size: size} <-
           Map.get(images, image_id),
         true <-
           artifact.id == id and Base.encode16(artifact.sha256, case: :lower) == sha256 and
             artifact.mime_type == mime and artifact.byte_size == size,
         {:ok, file} <- commit_generated_image(subject_uid, filename, sha256, mime, origin) do
      {:ok,
       %{
         "path" => file.path,
         "blob_ref" => Base.encode16(file.sha256, case: :lower),
         "name" => filename,
         "mime_type" => mime,
         "size" => file.size
       }}
    else
      reason -> generated_image_retry(image_id, reason)
    end
  end

  defp generated_image_extension(_image_id, "image/png"), do: {:ok, "png"}
  defp generated_image_extension(_image_id, "image/jpeg"), do: {:ok, "jpg"}
  defp generated_image_extension(_image_id, "image/webp"), do: {:ok, "webp"}
  defp generated_image_extension(_image_id, "image/gif"), do: {:ok, "gif"}

  defp generated_image_extension(image_id, mime_type),
    do: {:error, {:unsupported_generated_image_mime_type, image_id, mime_type}}

  defp commit_generated_image(agent_uid, filename, sha256, mime, origin) do
    channel_id = if origin, do: origin.id

    with {:ok, %{files: [file]}} <-
           Files.commit_in_tx(
             agent_uid,
             [
               %{
                 path:
                   Files.chat_path(channel_id, Files.content_path("generated", sha256, filename)),
                 sha256: sha256,
                 source: "generated",
                 conversation_id: channel_id,
                 content_type: mime
               }
             ],
             []
           ),
         do: {:ok, file}
  end

  defp generated_image_retry(image_id, reason) do
    {:error,
     %{
       "code" => "generated_image_materialization_failed",
       "message" => "Generated image #{image_id} must be prepared again: #{inspect(reason)}",
       "retryable" => true
     }}
  end

  defp dedupe_function_call_outputs(items) do
    {deduped, _seen_call_ids} =
      Enum.reduce(items, {[], MapSet.new()}, fn
        %{"type" => "function_call_output", "call_id" => call_id} = item, {acc, seen}
        when is_binary(call_id) ->
          if MapSet.member?(seen, call_id) do
            {acc, seen}
          else
            {[item | acc], MapSet.put(seen, call_id)}
          end

        item, {acc, seen} ->
          {[item | acc], seen}
      end)

    Enum.reverse(deduped)
  end
end
