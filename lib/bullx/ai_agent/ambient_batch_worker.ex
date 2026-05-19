defmodule BullX.AIAgent.AmbientBatchWorker do
  @moduledoc false

  use GenServer

  import Ecto.Query

  alias BullX.AIAgent.{AmbientBatch, Conversation, Conversations, Message, Profile, Runner}
  alias BullX.Principals.Agent
  alias BullX.Repo

  @interval_ms 1_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    schedule()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    process_due()
    schedule()
    {:noreply, state}
  end

  defp process_due do
    case AmbientBatch.due_batches() do
      {:ok, batch_keys} -> Enum.each(batch_keys, &process_batch/1)
      {:error, _reason} -> :ok
    end
  end

  defp process_batch(batch_key) do
    case AmbientBatch.take(batch_key) do
      {:ok, meta, items} ->
        handle_batch(batch_key, meta, items)

      :stale ->
        AmbientBatch.cleanup(batch_key)

      :locked ->
        :ok

      {:error, _reason} ->
        AmbientBatch.cleanup(batch_key)
    end
  end

  defp handle_batch(batch_key, meta, items) do
    with %Conversation{ended_at: nil} = conversation <-
           Repo.get(Conversation, meta["ambient_conversation_id"]),
         %Agent{profile: raw_profile} <- Repo.get(Agent, meta["agent_principal_id"]),
         {:ok, profile} <- Profile.cast(raw_profile),
         :may_intervene <- profile.unmentioned_group_messages,
         {:intervene, recognizer} <- recognizer_decision(profile, conversation, meta, items),
         {:ok, _conversation, message} <-
           write_introspection(conversation, meta, items, recognizer),
         :ok <-
           Runner.run(conversation, message, profile, %{
             source_type: "ambient_batch",
             source_id: batch_key,
             caller_principal_id: meta["agent_principal_id"],
             agent_principal_id: meta["agent_principal_id"],
             reply_channel: meta["reply_channel"],
             acl_context: %{source_type: "ambient_batch"}
           }) do
      AmbientBatch.cleanup(batch_key)
    else
      _other -> AmbientBatch.cleanup(batch_key)
    end
  end

  defp recognizer_decision(%Profile{} = profile, conversation, meta, items) do
    context = ambient_recognizer_context(conversation, meta)

    system_prompt =
      [
        profile.mission,
        "\n\n",
        profile.ambient_intent_system_prompt,
        "\n\nDecide whether this ambient batch requires this Agent to intervene. Return JSON only."
      ]
      |> IO.iodata_to_binary()

    user_prompt =
      [
        "Ambient recall:\n",
        Enum.map_join(context.ambient_recall, "\n", &("- " <> &1.text)),
        "\nAddressed context:\n",
        Enum.map_join(context.addressed_context, "\n", &("- " <> &1)),
        "\nAmbient batch:\n",
        Enum.map_join(items, "\n", &Map.get(&1, "text", ""))
      ]
      |> IO.iodata_to_binary()

    case BullX.LLM.chat(
           profile.compression_model,
           [
             %ReqLLM.Message{
               role: :system,
               content: [ReqLLM.Message.ContentPart.text(system_prompt)]
             },
             %ReqLLM.Message{
               role: :user,
               content: [ReqLLM.Message.ContentPart.text(user_prompt)]
             }
           ],
           []
         ) do
      {:ok, %{text: text} = result} ->
        case parse_intervention(text) do
          {:intervene, reason_summary} ->
            {:intervene,
             %{
               "usage" => result.usage,
               "provider_id" => result.provider_id,
               "model_id" => result.model_id,
               "reason_summary" => reason_summary
             }}

          :ignore ->
            :ignore
        end

      {:error, _reason} ->
        :ignore
    end
  end

  defp parse_intervention(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, %{"intervene" => true} = payload} ->
        {:intervene, safe_string(payload["reason_summary"], 240)}

      _other ->
        :ignore
    end
  end

  defp ambient_recognizer_context(conversation, meta) do
    scene = %{"scene_key" => meta["scene_key"]}
    scene_key = meta["scene_key"]

    ambient_recall =
      BullX.AIAgent.MessageContextBuilder.ambient_recall(
        conversation.agent_principal_id,
        scene,
        nil
      )

    addressed_context = addressed_context(conversation, scene_key)

    %{ambient_recall: ambient_recall, addressed_context: addressed_context}
  end

  defp write_introspection(conversation, meta, items, recognizer) do
    reason =
      recognizer["reason_summary"] ||
        "Ambient batch matched the Agent mission."

    Conversations.append_message(conversation, %{
      conversation_id: conversation.id,
      role: :im_ambient,
      kind: :introspection,
      status: :complete,
      content: [%{"type" => "text", "text" => "Ambient messages may require intervention."}],
      metadata: %{
        "ambient_batch_idempotency_key" => meta["batch_key"],
        "ambient" => %{
          "trigger_reason_summary" => reason,
          "recognizer" => Map.delete(recognizer, "reason_summary"),
          "batch_time_range" => batch_time_range(items),
          "reply_channel_hint" => reply_channel_hint(meta["reply_channel"]),
          "source_items" => Enum.map(items, &Map.take(&1, ["message_id", "text", "sent_at"]))
        },
        "scene" => %{"scene_key" => meta["scene_key"]}
      }
    })
  end

  defp addressed_context(%Conversation{} = conversation, scene_key) when is_binary(scene_key) do
    conversation_ids =
      Message
      |> join(:inner, [m], c in Conversation, on: c.id == m.conversation_id)
      |> where([m, c], c.agent_principal_id == ^conversation.agent_principal_id)
      |> where([m, c], fragment("?->'conversation_key_parts'->>'lane' = 'addressed'", c.metadata))
      |> where([m], m.role == :user and m.kind == :normal)
      |> where([m], fragment("?->'scene'->>'scene_key' = ?", m.metadata, ^scene_key))
      |> select([m], m.conversation_id)
      |> distinct(true)
      |> Repo.all()

    Message
    |> where([m], m.conversation_id in ^conversation_ids)
    |> where([m], (m.role == :user and m.kind == :normal) or m.role == :assistant)
    |> order_by([m], desc: m.inserted_at)
    |> limit(10)
    |> Repo.all()
    |> Enum.reverse()
    |> Enum.map(&message_text/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp addressed_context(_conversation, _scene_key), do: []

  defp batch_time_range(items) do
    items
    |> Enum.map(&parse_item_sent_at/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] ->
        %{}

      datetimes ->
        from = Enum.min_by(datetimes, &DateTime.to_unix(&1, :microsecond))
        to = Enum.max_by(datetimes, &DateTime.to_unix(&1, :microsecond))

        %{
          "from" => DateTime.to_iso8601(from),
          "to" => DateTime.to_iso8601(to)
        }
    end
  end

  defp parse_item_sent_at(%{"sent_at" => sent_at}) when is_binary(sent_at) do
    case DateTime.from_iso8601(sent_at) do
      {:ok, datetime, _offset} -> datetime
      _error -> nil
    end
  end

  defp parse_item_sent_at(_item), do: nil

  defp reply_channel_hint(%{} = reply_channel) do
    identity =
      reply_channel
      |> Map.take(["adapter", "channel_id", "thread_id", :adapter, :channel_id, :thread_id])
      |> stringify_keys()

    case map_size(identity) do
      0 ->
        nil

      _size ->
        %{
          "identity_hash" => "sha256:" <> BullX.Ext.generic_hash(Jason.encode!(identity)),
          "adapter" => identity["adapter"]
        }
    end
  end

  defp reply_channel_hint(_reply_channel), do: nil

  defp message_text(%BullX.AIAgent.Message{content: content}) do
    content
    |> Enum.filter(&(Map.get(&1, "type") in ["text", "summary_text"]))
    |> Enum.map_join("\n", &Map.get(&1, "text", ""))
    |> String.slice(0, 500)
  end

  defp safe_string(value, max_length) when is_binary(value),
    do: String.slice(value, 0, max_length)

  defp safe_string(_value, _max_length), do: nil

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp schedule, do: Process.send_after(self(), :poll, @interval_ms)
end
