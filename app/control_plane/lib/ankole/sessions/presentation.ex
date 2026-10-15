defmodule Ankole.Sessions.Presentation do
  @behaviour Ankole.Sessions.Tool
  @moduledoc "Publishes Driver activity and commits native statements or external Delivery intents."

  alias Ankole.Conversations.Delivery.Preview
  alias Ankole.Sessions.Queue
  alias Ankole.Signals.Signal
  alias Ankole.Conversations.Delivery
  alias Ankole.Conversations.Attachments
  alias Ankole.Schedule.Delivery, as: ScheduledDelivery
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
           Ankole.Repo.transact(fn repo ->
             with :ok <- Ankole.Sessions.Fence.check_in_tx(repo, run, :share),
                  :ok <-
                    Attachments.link_payload(
                      run.agent_uid,
                      Signal.envelope(run.delivered_event),
                      run.delivered_event.conversation_id
                    ),
                  do: {:ok, :linked}
           end) do
      with :ok <-
             Preview.maybe_start_for(run.event, run.agent_uid, run.conversation.id,
               driver: driver,
               run: run
             ) do
        events =
          Ankole.Sessions.Run.open_events(run)
          |> Enum.filter(&(&1.id in run.steer_event_ids))

        continue(run, events)
      end
    end
  end

  def reply_event(events, fallback) do
    events
    |> Enum.filter(fn event ->
      case Ankole.Conversations.Target.for_reply(Ankole.Repo, event) do
        {:ok, target} -> Ankole.Conversations.Target.reply_eligible?(target, event)
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
    payload = activity_payload(payload)
    Preview.presentation_event(run.event, %{"kind" => kind, "payload" => payload})
  end

  def activity(run, call, tool, args, phase, result \\ nil) do
    {key, bindings} =
      if tool.executor != :worker and function_exported?(tool.executor, :activity, 4),
        do: tool.executor.activity(tool, args, phase, result),
        else: {tool.activity, Map.take(args, ["name"])}

    if key do
      event(run, "tool.activity", %{
        "operation_id" => Ankole.Sessions.Run.call_id(call),
        "phase" => phase,
        "label_key" => "conversations.delivery.reply.activity.#{key}",
        "label_bindings" => bindings,
        "consequential" => tool.destructive == true
      })
    end
  end

  def waiting(run, call, %{kind: :job} = wait) do
    event(run, "tool.activity", %{
      "operation_id" => Ankole.Sessions.Run.call_id(call),
      "phase" => "running",
      "label_key" => "conversations.delivery.reply.activity.background_job_wait",
      "label_bindings" => %{"job" => wait.job_id, "seconds" => wait.timeout_ms / 1000}
    })
  end

  def waiting(_run, _call, _wait), do: :ok

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
    |> Map.put("label_key", activity["key"])
    |> Map.put("label_bindings", activity["bindings"] || %{})
  end

  defp activity_payload(%{"activity" => activity} = payload) when is_binary(activity),
    do: payload |> Map.delete("activity") |> Map.put("label", activity)

  defp activity_payload(payload), do: payload

  def stop(run), do: Preview.stop(run.event)

  @impl true
  def execute_in_tx(_repo, run, %{"name" => "reply_attachment"}, args) do
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

  def targets_in_tx(repo, event) do
    delivery =
      if event.type != "cron.fire" or Ankole.Sessions.Scheduled.produced_signal?(event),
        do: Signal.scheduled_delivery_snapshot(event)

    if is_map(delivery) do
      with {:ok, items} <- ScheduledDelivery.targets(delivery, event.reply_binding_name) do
        items
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, targets} ->
          case Ankole.Conversations.Target.for_delivery_in_tx(
                 repo,
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
      case Ankole.Conversations.Target.for_reply(repo, event) do
        {:ok, target} -> {:ok, [target]}
        {:error, :reply_route_unavailable} -> {:ok, []}
      end
    end
  end

  def post_in_tx(_repo, _event, %Ankole.Conversations.Statement{outcome: :silent}),
    do: {:ok, %Ankole.Conversations.PostResult{}}

  def post_in_tx(repo, event, statement) do
    :ok = Queue.lock_session_in_tx(repo, event.agent_uid, event.session_id)

    with {:ok, targets} <- targets_in_tx(repo, event) do
      targets =
        Enum.filter(targets, fn target ->
          statement.notice != nil or Ankole.Conversations.Target.reply_eligible?(target, event)
        end)

      Enum.reduce_while(targets, {:ok, %Ankole.Conversations.PostResult{}}, fn target,
                                                                               {:ok, posted} ->
        case Ankole.Conversations.post_in_tx(repo, target, statement) do
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
end
