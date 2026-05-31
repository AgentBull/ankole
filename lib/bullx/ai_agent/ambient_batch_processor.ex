defmodule BullX.AIAgent.AmbientBatchProcessor do
  @moduledoc """
  Turns coalesced ambient IM messages into optional Agent intervention.

  Ambient messages are observations by default. This processor only escalates a
  batch into an Agent run when the profile allows intervention and a lightweight
  recognizer decides the recent scene is relevant enough to materialize an
  introspection message.
  """

  require Logger

  import Ecto.Query

  alias BullX.AIAgent.{AmbientBatch, Conversation, Conversations, Message, Profile, Runner}
  alias BullX.Principals.Agent
  alias BullX.Repo

  @supervisor BullX.AIAgent.AmbientBatchTaskSupervisor

  @spec start(String.t()) :: :ok
  def start(batch_key) when is_binary(batch_key) do
    start_child(fn -> process_batch(batch_key) end)
  end

  @spec process_batch(String.t()) :: :ok
  def process_batch(batch_key) when is_binary(batch_key) do
    case AmbientBatch.take(batch_key) do
      {:ok, meta, items} -> handle_batch(batch_key, meta, items)
      :stale -> :ok
      {:error, _reason} -> :ok
    end
  end

  @spec batch_idempotency_key(map(), [map()]) :: String.t()
  def batch_idempotency_key(meta, items) when is_map(meta) and is_list(items) do
    %{
      "v" => 1,
      "scope" => meta["batch_key"],
      "items" => Enum.map(items, &batch_item_identity/1) |> Enum.sort()
    }
    |> Jason.encode!()
    |> BullX.Ext.generic_hash()
    |> then(&("ambient_batch:" <> &1))
  end

  defp start_child(fun) when is_function(fun, 0) do
    case Process.whereis(@supervisor) do
      nil ->
        _result = Task.start(fun)
        :ok

      _pid ->
        _result = Task.Supervisor.start_child(@supervisor, fun)
        :ok
    end
  end

  defp handle_batch(batch_key, meta, items) do
    # Non-intervention is a normal outcome; only log real downstream errors.
    with %Conversation{ended_at: nil} = conversation <-
           Repo.get(Conversation, meta["ambient_conversation_id"]),
         %Agent{profile: raw_profile} <- Repo.get(Agent, meta["agent_uid"]),
         {:ok, profile} <- Profile.cast(raw_profile),
         :may_intervene <- ambient_mode(profile, meta),
         {:intervene, recognizer} <- recognizer_decision(profile, conversation, meta, items),
         idempotency_key <- batch_idempotency_key(meta, items),
         {:ok, _conversation, message} <-
           write_introspection(conversation, meta, items, recognizer, idempotency_key),
         :ok <-
           Runner.run(conversation, message, profile, %{
             trigger_type: "ambient_batch",
             trigger_id: idempotency_key,
             caller_principal_uid: meta["agent_uid"],
             agent_uid: meta["agent_uid"],
             reply_address: meta["reply_address"],
             acl_context: %{trigger_type: "ambient_batch"}
           }) do
      :ok
    else
      {:error, reason} ->
        Logger.warning(
          "ambient_batch_processor: pipeline error, dropping batch " <>
            "(batch_key=#{inspect(batch_key)} reason=#{inspect(reason)})"
        )

        :ok

      _other ->
        :ok
    end
  end

  defp ambient_mode(_profile, %{"ambient_mode" => "may_intervene"}), do: :may_intervene
  defp ambient_mode(_profile, %{"ambient_mode" => "observe_only"}), do: :observe_only
  defp ambient_mode(_profile, _meta), do: :observe_only

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
           profile.compression_llm,
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
        conversation.agent_uid,
        scene,
        nil
      )

    addressed_context = addressed_context(conversation, scene_key)

    %{ambient_recall: ambient_recall, addressed_context: addressed_context}
  end

  defp batch_item_identity(item) when is_map(item) do
    ["message_id", "sent_at", "text"]
    |> Enum.map(fn key -> [key, Map.get(item, key, "")] end)
  end

  defp write_introspection(conversation, meta, items, recognizer, idempotency_key) do
    # The runner is triggered by a normal conversation message, not by the batch
    # directly. That keeps ambient intervention explainable in transcript
    # history and gives lifecycle code a concrete message to revise later.
    reason =
      recognizer["reason_summary"] ||
        "Ambient batch matched the Agent mission."

    Conversations.append_message(conversation, %{
      role: :im_ambient,
      kind: :introspection,
      status: :complete,
      content: [%{"type" => "text", "text" => "Ambient messages may require intervention."}],
      metadata: %{
        "ambient_batch_idempotency_key" => idempotency_key,
        "ambient" => %{
          "trigger_reason_summary" => reason,
          "recognizer" => Map.delete(recognizer, "reason_summary"),
          "batch_time_range" => batch_time_range(items),
          "reply_address_hint" => reply_address_hint(meta["reply_address"]),
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
      |> where([m, c], c.agent_uid == ^conversation.agent_uid)
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

  defp reply_address_hint(%{} = reply_address) do
    identity =
      reply_address
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

  defp reply_address_hint(_reply_address), do: nil

  defp message_text(%Message{content: content}) do
    content
    |> Enum.filter(&(Map.get(&1, "type") in ["text", "summary_text"]))
    |> Enum.map_join("\n", &Map.get(&1, "text", ""))
    |> String.slice(0, 500)
  end

  defp safe_string(value, max_length) when is_binary(value),
    do: String.slice(value, 0, max_length)

  defp safe_string(_value, _max_length), do: nil

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
