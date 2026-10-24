defmodule Ankole.Conversations.NativeQueue do
  @moduledoc false

  require Ash.Query

  alias Ankole.{Repo, Signals}
  alias Ankole.Conversations.{Conversation, Message, ModelPreferences, Native, Queries}
  alias Ankole.Signals.Signal

  @addressed "conversation.message.addressed"

  @doc "Changes only native follow-ups that have not been admitted to a turn."
  def update_queue(human_uid, id, attrs) when is_map(attrs) do
    Repo.transact_top_level(
      fn -> update_queue_in_tx(human_uid, id, attrs) end,
      after_commit: &Native.publish_native_change/1
    )
    |> Native.committed(human_uid)
  end

  def update_queue(_human_uid, _id, _attrs), do: {:error, :invalid_request}

  @doc false
  def update_queue_in_tx(human_uid, id, attrs) do
    with {:ok, id} <- Queries.cast_id(id),
         %Conversation{} = visible <- Native.visible_conversation(human_uid, id),
         %{} = agent <- Native.conversation_agent(id),
         session_id = Ankole.Sessions.Key.conversation(id),
         :ok <- Native.lock_participants_in_tx(human_uid, agent.uid),
         :ok <-
           Signals.lock_target_in_tx(%{
             agent_uid: agent.uid,
             session_id: session_id
           }),
         :ok <- Native.check_human_in_tx(human_uid),
         :ok <- Native.authorize_page(human_uid, visible.page_id),
         %Conversation{} = conversation <- Native.visible_conversation(human_uid, id, lock: true),
         inputs = Signals.lock_signals_in_tx(Native.pending_filter(id)),
         true <- Enum.all?(inputs, &(&1.human_uid == human_uid)),
         {:ok, accepted_retry} <- accepted_retry(conversation, agent, attrs),
         :ok <-
           if(accepted_retry, do: :ok, else: check_queue_version(conversation, inputs, attrs)),
         {:ok, changed} <-
           if(accepted_retry,
             do: {:ok, [accepted_retry]},
             else: change_queue_in_tx(human_uid, conversation, agent, inputs, attrs)
           ),
         :ok <-
           Ankole.Sessions.Jobs.EnsureDriver.enqueue_in_tx(
             %{agent_uid: agent.uid, session_id: session_id},
             DateTime.utc_now(:microsecond)
           ) do
      removed_ids = for input <- changed, input.data["removed"] == true, do: input.message_id

      {:ok,
       %{
         id: id,
         session_key: %{agent_uid: agent.uid, session_id: session_id},
         publications: [{id, :message}],
         removed_message_ids: removed_ids
       }}
    else
      nil -> {:error, :conversation_not_found}
      false -> {:error, :invalid_request}
      error -> error
    end
  end

  @doc "A derived version of the pending queue and its latest explicit pause."
  def queue_version(conversation, inputs) do
    snapshot = [
      conversation.metadata["queue_paused"] == true,
      conversation.metadata["queue_pause_command_id"],
      Enum.map(
        inputs,
        &[&1.message_id, &1.data["text"], &1.data["delivery_mode"] || "steer", &1.queue_sequence]
      )
    ]

    :crypto.hash(:sha256, Ankole.JSON.encode!(snapshot)) |> Base.encode16(case: :lower)
  end

  @doc false
  def retryable_reply?(%Message{kind: :message}, %Signal{}), do: true

  def retryable_reply?(%Message{kind: :notice}, %Signal{
        status: :dead_letter,
        last_attempt_at: %DateTime{}
      }),
      do: true

  def retryable_reply?(_, _), do: false

  defp check_queue_version(conversation, inputs, attrs) do
    if Ankole.Attrs.get(attrs, :action) == "stop" or
         Ankole.Attrs.get(attrs, :expected_version) == queue_version(conversation, inputs),
       do: :ok,
       else: {:error, :queue_changed}
  end

  defp change_queue_in_tx(human_uid, conversation, agent, inputs, attrs) do
    case Ankole.Attrs.get(attrs, :action) do
      "stop" ->
        stop_queue_in_tx(human_uid, conversation, agent, inputs, attrs)

      "resume" ->
        with {:ok, _} <- put_queue_pause(conversation, false), do: {:ok, []}

      "reorder" ->
        reorder_inputs(inputs, Ankole.Attrs.get(attrs, :message_ids))

      action when action in ["regenerate", "edit_last"] ->
        retry_last_in_tx(human_uid, conversation, agent, action, attrs)

      action when action in ["edit", "send_now", "remove"] ->
        with {:ok, id} <- Queries.cast_id(Ankole.Attrs.get(attrs, :message_id)),
             %Signal{} = input <-
               Enum.find(inputs, &(&1.message_id == id and &1.human_uid == human_uid)) do
          with {:ok, changed} <- change_input_in_tx(input, action, attrs) do
            if action == "send_now",
              do: reorder_inputs(inputs, [id | Enum.map(inputs, & &1.message_id) -- [id]]),
              else: {:ok, changed}
          end
        else
          nil -> {:error, :input_already_started}
          error -> error
        end

      _ ->
        {:error, :invalid_request}
    end
  end

  defp retry_command_data(action, message_id, attrs) do
    %{
      "native_action" => action,
      "native_message_id" => message_id,
      "native_edit_text" => if(action == "edit_last", do: Ankole.Attrs.get(attrs, :text))
    }
  end

  defp accepted_retry(conversation, agent, attrs) do
    action = Ankole.Attrs.get(attrs, :action)

    if action in ["regenerate", "edit_last"] do
      with {:ok, command_id} <- Queries.cast_id(Ankole.Attrs.get(attrs, :command_id)),
           {:ok, message_id} <- Queries.cast_id(Ankole.Attrs.get(attrs, :message_id)) do
        data = retry_command_data(action, message_id, attrs)

        case control_signal(agent, conversation, command_id) do
          %Signal{type: "command.retry", status: :completed} = existing ->
            if Map.take(existing.data, Map.keys(data)) == data,
              do: {:ok, existing},
              else: {:error, :conversation_conflict}

          nil ->
            {:ok, nil}

          _other ->
            {:error, :conversation_conflict}
        end
      end
    else
      {:ok, nil}
    end
  end

  defp control_signal(agent, conversation, command_id) do
    Signals.list_signals!(
      query: [
        filter: [
          agent_uid: agent.uid,
          source: "native-control:" <> conversation.id,
          source_event_id: command_id
        ]
      ]
    )
    |> List.first()
  end

  defp retry_last_in_tx(human_uid, conversation, agent, action, attrs) do
    with {:ok, command_id} <- Queries.cast_id(Ankole.Attrs.get(attrs, :command_id)),
         {:ok, message_id} <- Queries.cast_id(Ankole.Attrs.get(attrs, :message_id)) do
      key = %{agent_uid: agent.uid, session_id: Ankole.Sessions.Key.conversation(conversation.id)}
      now = DateTime.utc_now(:microsecond)

      with %Message{} = message <- Queries.conversation_message(conversation.id, message_id),
           %Signal{} = input <- retry_input(human_uid, message, action),
           {:ok, command} <-
             Signals.accept_in_tx(%{
               producer: :kernel,
               source: "native-control:" <> conversation.id,
               id: command_id,
               type: "command.retry",
               subject: conversation.id,
               target: %{agent_uid: agent.uid, conversation_id: conversation.id},
               sender: human_uid,
               data:
                 Map.put(retry_command_data(action, message_id, attrs), "command", %{
                   "targetSignalId" => input.id
                 })
             }),
           {:ok, %Signal{}} <-
             Ankole.Sessions.Commands.retry_source_in_tx(key, command, input.id),
           :ok <- ModelPreferences.authorize_input(conversation, agent.uid, "queue", true),
           :ok <- edit_last_in_tx(message, action, attrs),
           {:ok, retry} <- Ankole.Sessions.Commands.retry_in_tx(key, command, now),
           {:ok, retry} <-
             Signals.update_metadata_signal(retry, %{
               data: Map.put(retry.data, "model_profile", ModelPreferences.logical(conversation))
             }),
           :ok <- remove_native_reply_in_tx(conversation.id, input.id, now) do
        {:ok, [retry]}
      else
        {:ok, :target_unavailable} -> {:error, :reply_unavailable}
        nil -> {:error, :reply_unavailable}
        error -> error
      end
    end
  end

  defp remove_native_reply_in_tx(conversation_id, signal_id, now) do
    # Native replies have no external Delivery intent. Replace their visible
    # statement while retaining independently created Pages and tool history.
    Message
    |> Ash.Query.filter(
      conversation_id == ^conversation_id and signal_id == ^signal_id and author_type == :agent
    )
    |> Ash.Query.lock(:for_update)
    |> Ankole.Ash.read!()
    |> Enum.reduce_while(:ok, fn message, :ok ->
      with :ok <- Queries.message_changed_in_tx(message, nil, now),
           {:ok, _} <- Ankole.Ash.destroy(message, :remove) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp retry_input(
         human_uid,
         %Message{author_type: :human, author_uid: human_uid} = message,
         "edit_last"
       ) do
    Signals.lock_signals_in_tx(
      [message_id: message.id, conversation_id: message.conversation_id, type: @addressed],
      sort: [queue_sequence: :desc],
      limit: 1
    )
    |> List.first()
  end

  defp retry_input(
         _human_uid,
         %Message{author_type: :agent, signal_id: signal_id} = message,
         "regenerate"
       )
       when not is_nil(signal_id) do
    case Signals.lock_signal_in_tx(signal_id) do
      %Signal{} = input -> if retryable_reply?(message, input), do: input
      nil -> nil
    end
  end

  defp retry_input(_human_uid, _message, _action), do: nil

  defp edit_last_in_tx(_message, "regenerate", _attrs), do: :ok

  defp edit_last_in_tx(message, "edit_last", attrs) do
    if Ankole.Attrs.get(attrs, :expected_text) == (message.text || "") do
      with {:ok, text} <- Native.native_text(Ankole.Attrs.get(attrs, :text), message.attachments),
           {:ok, updated} <-
             Ankole.Ash.update(message, :edit, %{text: text, links: Native.page_links(text)}),
           :ok <-
             Queries.message_changed_in_tx(message, updated, DateTime.utc_now(:microsecond)),
           do: :ok
    else
      {:error, :queue_changed}
    end
  end

  defp put_queue_pause(conversation, paused, command_id \\ nil) do
    metadata = Map.put(conversation.metadata, "queue_paused", paused)

    metadata =
      if command_id, do: Map.put(metadata, "queue_pause_command_id", command_id), else: metadata

    Ankole.Ash.update(conversation, :put_metadata, %{metadata: metadata})
  end

  defp stop_queue_in_tx(human_uid, conversation, agent, inputs, attrs) do
    with {:ok, command_id} <- Queries.cast_id(Ankole.Attrs.get(attrs, :command_id)) do
      case control_signal(agent, conversation, command_id) do
        %Signal{} = existing ->
          {:ok, [existing]}

        nil ->
          with {:ok, paused} <- pause_inputs(inputs),
               {:ok, _} <- put_queue_pause(conversation, true, command_id),
               {:ok, event} <-
                 Signals.accept_in_tx(%{
                   producer: :kernel,
                   source: "native-control:" <> conversation.id,
                   id: command_id,
                   type: "command.stop",
                   subject: conversation.id,
                   target: %{agent_uid: agent.uid, conversation_id: conversation.id},
                   sender: human_uid,
                   data: %{"conversation_id" => conversation.id}
                 }),
               do: {:ok, [event | paused]}
      end
    end
  end

  defp pause_inputs(inputs) do
    Enum.reduce_while(inputs, {:ok, []}, fn input, {:ok, paused} ->
      case Signals.update_metadata_signal(input, %{
             data: Map.put(input.data, "delivery_mode", "queue")
           }) do
        {:ok, input} -> {:cont, {:ok, [input | paused]}}
        error -> {:halt, error}
      end
    end)
  end

  defp change_input_in_tx(input, "edit", attrs) do
    with %Message{} = message <- Native.message(input.message_id),
         {:ok, text} <- Native.native_text(Ankole.Attrs.get(attrs, :text), message.attachments),
         {:ok, updated} <-
           Ankole.Ash.update(message, :edit, %{text: text, links: Native.page_links(text)}),
         :ok <-
           Queries.message_changed_in_tx(message, updated, DateTime.utc_now(:microsecond)),
         {:ok, input} <-
           Signals.update_metadata_signal(input, %{
             data: put_input_text(input.data, text)
           }),
         do: {:ok, [input]}
  end

  defp change_input_in_tx(input, "send_now", _attrs) do
    with :ok <-
           ModelPreferences.ensure_can_steer(
             input.agent_uid,
             input.conversation_id,
             input.data["model_profile"] || "primary"
           ),
         {:ok, input} <-
           Signals.update_metadata_signal(input, %{
             data: Map.put(input.data, "delivery_mode", "steer")
           }),
         do: {:ok, [input]}
  end

  defp change_input_in_tx(input, "remove", _attrs) do
    # Retain the accepted identity so a late POST retry cannot recreate removed input.
    now = DateTime.utc_now(:microsecond)

    with %Message{} = message <- Native.message(input.message_id),
         :ok <- Queries.message_changed_in_tx(message, nil, now),
         {:ok, input} <-
           Signals.update_metadata_signal(input, %{
             data: Map.put(input.data, "removed", true)
           }),
         {:ok, input} <- Ankole.Sessions.Queue.mark_event_completed_in_tx(input, now),
         do: {:ok, [input]}
  end

  defp put_input_text(data, text) do
    data = Map.put(data, "text", text)
    if is_map(data["entry"]), do: put_in(data, ["entry", "text"], text), else: data
  end

  defp reorder_inputs(inputs, ids) when is_list(ids) do
    current_ids = Enum.map(inputs, & &1.message_id)

    if length(ids) == length(current_ids) and MapSet.new(ids) == MapSet.new(current_ids) do
      by_id = Map.new(inputs, &{&1.message_id, &1})
      # Allocate above the high-water mark to preserve the unique sequence constraint.
      maximum =
        case inputs do
          [input | _] -> max_queue_sequence(input)
          [] -> 0
        end

      ids
      |> Enum.with_index((maximum || 0) + 1)
      |> Enum.reduce_while({:ok, []}, fn {id, sequence}, {:ok, changed} ->
        case Signals.update_metadata_signal(Map.fetch!(by_id, id), %{
               queue_sequence: sequence
             }) do
          {:ok, input} -> {:cont, {:ok, [input | changed]}}
          error -> {:halt, error}
        end
      end)
    else
      {:error, :queue_changed}
    end
  end

  defp reorder_inputs(_inputs, _ids), do: {:error, :invalid_request}

  defp max_queue_sequence(input) do
    case Signals.list_signals!(
           query: [
             filter: [agent_uid: input.agent_uid, session_id: input.session_id],
             sort: [queue_sequence: :desc],
             limit: 1,
             select: [:queue_sequence]
           ]
         ) do
      [%Signal{queue_sequence: sequence}] -> sequence
      [] -> nil
    end
  end
end
