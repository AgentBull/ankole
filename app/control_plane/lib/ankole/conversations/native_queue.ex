defmodule Ankole.Conversations.NativeQueue do
  @moduledoc false

  require Ash.Query

  alias Ankole.{Repo, Signals}
  alias Ankole.Conversations.{Conversation, Message, ModelPreferences, Native, Queries}
  alias Ankole.Signals.Signal

  @addressed "conversation.message.addressed"

  @doc "Changes only native follow-ups that have not been admitted to a turn."
  def update_queue(%Ankole.AuthZ.Actor{} = actor, id, attrs) when is_map(attrs) do
    Repo.transact_top_level(
      fn -> update_queue_in_tx(actor, id, attrs) end,
      after_commit: &Native.publish_native_change/1
    )
    |> Native.committed(actor)
  end

  def update_queue(_human_uid, _id, _attrs), do: {:error, :invalid_request}

  @doc false
  def update_queue_in_tx(%Ankole.AuthZ.Actor{} = actor, id, attrs) do
    with {:ok, id} <- Queries.cast_id(id),
         %Conversation{} = visible <- Native.visible_conversation(actor, id),
         %{} = agent <-
           Enum.find(Native.room_agents(id), &(&1.uid == Ankole.Attrs.get(attrs, :agent_uid))),
         session_id = Ankole.Sessions.Key.conversation(id),
         affected_uids = queue_agent_uids(id, agent.uid, attrs),
         {:ok, _} <-
           Ankole.Principals.lock_principals_in_tx([
             Ankole.AuthZ.Actor.uid(actor),
             visible.created_by | affected_uids
           ]),
         :ok <-
           Ankole.Sessions.Queue.lock_sessions_in_tx(Enum.map(affected_uids, &{&1, session_id})),
         :ok <- Native.check_human_in_tx(actor),
         :ok <- Native.authorize_agent(actor, agent.uid),
         %Conversation{} = conversation <- Native.visible_conversation(actor, id, lock: true),
         inputs =
           Signals.lock_signals_in_tx([{:agent_uid, agent.uid} | Native.pending_filter(id)]),
         {:ok, accepted_retry} <- accepted_retry(conversation, agent, attrs),
         :ok <-
           if(accepted_retry,
             do: :ok,
             else: check_queue_version(conversation, inputs, attrs, agent.uid)
           ),
         {:ok, changed} <-
           if(accepted_retry,
             do: {:ok, [accepted_retry]},
             else:
               change_queue_in_tx(
                 actor,
                 conversation,
                 agent,
                 inputs,
                 Map.put(attrs, :locked_agent_uids, affected_uids)
               )
           ),
         :ok <-
           Ankole.Sessions.Jobs.EnsureDriver.enqueue_in_tx(
             %{agent_uid: agent.uid, session_id: session_id},
             DateTime.utc_now(:microsecond)
           ) do
      removed = for input <- changed, input.data["removed"] == true, do: input.message_id

      removed_ids =
        Message
        |> Ash.Query.filter(id in ^removed and withdrawn)
        |> Ash.Query.select([:id])
        |> Ankole.Ash.read!()
        |> Enum.map(& &1.id)

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

  defp queue_agent_uids(id, selected, attrs) do
    if Ankole.Attrs.get(attrs, :action) == "edit" do
      inputs =
        Signals.list_signals!(
          query: [
            filter: [
              conversation_id: id,
              message_id: Ankole.Attrs.get(attrs, :message_id),
              type: @addressed
            ]
          ]
        )

      Enum.uniq([selected | Enum.map(inputs, & &1.agent_uid)])
    else
      [selected]
    end
  end

  @doc "A derived version of the pending queue and its latest explicit pause."
  def queue_version(conversation, inputs, agent_uid) do
    message_ids = Enum.map(inputs, & &1.message_id)

    references_by_id =
      if message_ids == [] do
        %{}
      else
        Message
        |> Ash.Query.filter(id in ^message_ids)
        |> Ash.Query.select([:id, :links, :mentions])
        |> Ankole.Ash.read!()
        |> Map.new(&{&1.id, [&1.links, &1.mentions]})
      end

    snapshot = [
      conversation.metadata["queue_paused:" <> agent_uid] == true,
      conversation.metadata["queue_pause_command_id:" <> agent_uid],
      Enum.map(
        inputs,
        &[
          &1.message_id,
          &1.data["text"],
          Map.fetch!(references_by_id, &1.message_id),
          &1.data["delivery_mode"] || "steer",
          &1.queue_sequence
        ]
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

  defp check_queue_version(conversation, inputs, attrs, agent_uid) do
    if Ankole.Attrs.get(attrs, :action) == "stop" or
         Ankole.Attrs.get(attrs, :expected_version) ==
           queue_version(conversation, inputs, agent_uid),
       do: :ok,
       else: {:error, :queue_changed}
  end

  defp change_queue_in_tx(%Ankole.AuthZ.Actor{} = actor, conversation, agent, inputs, attrs) do
    human_uid = Ankole.AuthZ.Actor.uid(actor)

    case Ankole.Attrs.get(attrs, :action) do
      "stop" ->
        stop_queue_in_tx(actor, conversation, agent, inputs, attrs)

      "resume" ->
        with {:ok, _} <- put_queue_pause(conversation, agent.uid, false), do: {:ok, []}

      "reorder" ->
        reorder_inputs(inputs, Ankole.Attrs.get(attrs, :message_ids))

      action when action in ["regenerate", "edit_last"] ->
        retry_last_in_tx(actor, conversation, agent, action, attrs)

      action when action in ["edit", "steer", "retract"] ->
        with {:ok, id} <- Queries.cast_id(Ankole.Attrs.get(attrs, :message_id)),
             %Signal{} = input <-
               Enum.find(inputs, &(&1.message_id == id and &1.human_uid == human_uid)) do
          with {:ok, changed} <- change_selected_input_in_tx(input, action, attrs) do
            if action == "steer",
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
    data = %{
      "native_action" => action,
      "native_message_id" => message_id,
      "native_edit_text" => if(action == "edit_last", do: Ankole.Attrs.get(attrs, :text))
    }

    data =
      case Ankole.Attrs.get(attrs, :links) do
        nil -> data
        links -> Map.put(data, "native_edit_links", canonical_links(links))
      end

    case Ankole.Attrs.get(attrs, :mentions) do
      nil -> data
      mentions -> Map.put(data, "native_edit_mentions", canonical_mentions(mentions))
    end
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

  defp retry_last_in_tx(%Ankole.AuthZ.Actor{} = actor, conversation, agent, action, attrs) do
    human_uid = Ankole.AuthZ.Actor.uid(actor)

    with {:ok, command_id} <- Queries.cast_id(Ankole.Attrs.get(attrs, :command_id)),
         {:ok, message_id} <- Queries.cast_id(Ankole.Attrs.get(attrs, :message_id)) do
      key = %{agent_uid: agent.uid, session_id: Ankole.Sessions.Key.conversation(conversation.id)}
      now = DateTime.utc_now(:microsecond)

      with %Message{} = message <- Queries.conversation_message(conversation.id, message_id),
           :ok <- edit_last_scope(message, action),
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
               data:
                 Map.put(
                   retry.data,
                   "model_profile",
                   ModelPreferences.logical(conversation, agent.uid)
                 )
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

  defp edit_last_scope(_message, "regenerate"), do: :ok

  defp edit_last_scope(message, "edit_last") do
    if length(addressed_agent_uids(message)) > 1,
      do: {:error, :input_already_started},
      else: :ok
  end

  @doc "Returns a native message's actual Agent recipients, including silent turns."
  def addressed_agent_uids(message) do
    Signals.list_signals!(
      query: [
        filter: [
          message_id: message.id,
          conversation_id: message.conversation_id,
          type: @addressed
        ]
      ]
    )
    |> Enum.reject(&(&1.data["removed"] == true))
    |> Enum.map(& &1.agent_uid)
    |> Enum.uniq()
    |> Enum.sort()
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
    expected_links = Ankole.Attrs.get(attrs, :expected_links)
    expected_mentions = Ankole.Attrs.get(attrs, :expected_mentions)

    if Ankole.Attrs.get(attrs, :expected_text) == (message.text || "") and
         (is_nil(expected_links) or
            canonical_links(expected_links) == canonical_links(message.links)) and
         (is_nil(expected_mentions) or
            canonical_mentions(expected_mentions) == canonical_mentions(message.mentions)) do
      with {:ok, _} <- edit_message_in_tx(message, attrs), do: :ok
    else
      {:error, :queue_changed}
    end
  end

  defp put_queue_pause(conversation, agent_uid, paused, command_id \\ nil) do
    metadata = Map.put(conversation.metadata, "queue_paused:" <> agent_uid, paused)

    metadata =
      if command_id,
        do: Map.put(metadata, "queue_pause_command_id:" <> agent_uid, command_id),
        else: metadata

    Ankole.Ash.update(conversation, :put_metadata, %{metadata: metadata})
  end

  defp stop_queue_in_tx(%Ankole.AuthZ.Actor{} = actor, conversation, agent, inputs, attrs) do
    human_uid = Ankole.AuthZ.Actor.uid(actor)

    with {:ok, command_id} <- Queries.cast_id(Ankole.Attrs.get(attrs, :command_id)) do
      case control_signal(agent, conversation, command_id) do
        %Signal{} = existing ->
          {:ok, [existing]}

        nil ->
          with {:ok, paused} <- pause_inputs(inputs),
               {:ok, _} <- put_queue_pause(conversation, agent.uid, true, command_id),
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
               {:ok, event} <- settle_idle_stop_in_tx(event),
               do: {:ok, [event | paused]}
      end
    end
  end

  defp settle_idle_stop_in_tx(event) do
    if Ankole.Sessions.Queue.oldest_started(event.agent_uid, event.session_id) do
      {:ok, event}
    else
      key = Map.take(event, [:agent_uid, :session_id])

      with {:ok, %{signal: completed}} <-
             Ankole.Sessions.Commands.apply_command_in_tx(
               key,
               event,
               DateTime.utc_now(:microsecond)
             ),
           do: {:ok, completed}
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

  defp change_selected_input_in_tx(input, "edit", attrs) do
    targets =
      Signals.lock_signals_in_tx(
        conversation_id: input.conversation_id,
        message_id: input.message_id,
        type: @addressed
      )
      |> Enum.reject(&(&1.data["removed"] == true))

    locked = MapSet.new(attrs.locked_agent_uids)

    cond do
      Enum.any?(targets, &(not MapSet.member?(locked, &1.agent_uid))) ->
        {:error, :queue_changed}

      Enum.any?(
        targets,
        &(&1.status not in [:queued, :running] or not is_nil(&1.last_attempt_at))
      ) ->
        {:error, :input_already_started}

      true ->
        with {:ok, [edited]} <- change_input_in_tx(input, "edit", attrs),
             do: update_shared_inputs_in_tx(targets, edited)
    end
  end

  defp change_selected_input_in_tx(input, action, attrs),
    do: change_input_in_tx(input, action, attrs)

  defp update_shared_inputs_in_tx(targets, edited) do
    targets
    |> Enum.reject(&(&1.id == edited.id))
    |> Enum.reduce_while({:ok, [edited]}, fn target, {:ok, changed} ->
      case Signals.update_metadata_signal(target, %{
             data: put_input_text(target.data, edited.data["text"])
           }) do
        {:ok, updated} -> {:cont, {:ok, [updated | changed]}}
        error -> {:halt, error}
      end
    end)
  end

  defp change_input_in_tx(input, "edit", attrs) do
    with %Message{} = message <- Native.message(input.message_id),
         {:ok, message} <- edit_message_in_tx(message, attrs),
         {:ok, input} <-
           Signals.update_metadata_signal(input, %{
             data: put_input_text(input.data, message.text)
           }),
         do: {:ok, [input]}
  end

  defp change_input_in_tx(input, "steer", _attrs) do
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

  defp change_input_in_tx(input, "retract", _attrs) do
    # Retain the accepted identity so a late POST retry cannot recreate removed input.
    now = DateTime.utc_now(:microsecond)

    with %Message{} = message <- Native.message(input.message_id),
         {:ok, input} <-
           Signals.update_metadata_signal(input, %{data: Map.put(input.data, "removed", true)}),
         {:ok, input} <- Ankole.Sessions.Queue.mark_event_completed_in_tx(input, now),
         :ok <- invalidate_withdrawn(message, now),
         do: {:ok, [input]}
  end

  defp edit_message_in_tx(message, attrs) do
    with {:ok, text} <- Native.native_text(Ankole.Attrs.get(attrs, :text), message.attachments),
         {:ok, updated} <-
           Ankole.Ash.update(message, :edit, %{
             text: text,
             links: edited_links(message, text, attrs),
             mentions: edited_mentions(message, attrs)
           }),
         :ok <- Queries.message_changed_in_tx(message, updated, DateTime.utc_now(:microsecond)),
         do: {:ok, updated}
  end

  defp invalidate_withdrawn(message, now) do
    withdrawn =
      Message |> Ash.Query.filter(id == ^message.id and withdrawn) |> Ankole.Ash.read_one!()

    if withdrawn, do: Queries.message_changed_in_tx(message, nil, now), else: :ok
  end

  defp put_input_text(data, text) do
    data = Map.put(data, "text", text)
    if is_map(data["entry"]), do: put_in(data, ["entry", "text"], text), else: data
  end

  defp edited_links(message, text, attrs) do
    links = Ankole.Attrs.get(attrs, :links) || message.links
    Enum.uniq(Native.page_links(text) ++ canonical_links(links))
  end

  defp edited_mentions(message, attrs) do
    case Ankole.Attrs.get(attrs, :mentions) do
      nil ->
        message.mentions

      mentions ->
        human_uids =
          for mention <- canonical_mentions(mentions),
              mention["type"] == "human",
              do: mention["uid"]

        Enum.filter(message.mentions, &(&1["type"] != "human" or &1["uid"] in human_uids))
    end
  end

  @doc false
  def canonical_links(links), do: canonical_references(links, "kind")
  @doc false
  def canonical_mentions(mentions), do: canonical_references(mentions, "type")

  defp canonical_references(references, type_key),
    do:
      Enum.map(references, fn reference ->
        reference
        |> Map.new(fn {key, value} -> {to_string(key), value} end)
        |> Map.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.update!(type_key, &to_string/1)
      end)

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
      |> Enum.with_index(maximum + 1)
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
    [latest] =
      Signals.list_signals!(
        query: [
          filter: [agent_uid: input.agent_uid, session_id: input.session_id],
          sort: [queue_sequence: :desc],
          limit: 1,
          select: [:queue_sequence]
        ]
      )

    latest.queue_sequence
  end
end
