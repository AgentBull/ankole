defmodule Ankole.Conversations do
  @moduledoc "Owns conversations, participation, and committed messages."
  import Ecto.Query

  alias Ankole.Conversations.Target, as: StatementTarget
  alias Ankole.AIGateway
  alias Ankole.Conversations.Conversation
  alias Ankole.Conversations.Message
  alias Ankole.Conversations.ModelPreferences
  alias Ankole.Conversations.Participant
  alias Ankole.Principals.Principal
  alias Ankole.Principals.WorkAccess
  alias Ankole.Signals.Signal
  alias Ankole.{Repo, Signals}

  @doc "Commits the effects of a visible Message change with its observation."
  def message_changed_in_tx(repo, before_message, after_message, now) do
    if before_message != nil and after_message == nil do
      :ok = Ankole.Sessions.AmbientCuration.message_removed_in_tx(repo, before_message)
    end

    fields = [
      :text,
      :author_type,
      :author_uid,
      :attachments,
      :links,
      :mentions,
      :rich_content,
      :reply_to_message_id
    ]

    changed? =
      before_message != nil and
        (after_message == nil or
           Map.take(before_message, fields) != Map.take(after_message, fields))

    if changed? do
      Ankole.Brain.Sources.invalidate_conversation_message_in_tx(repo, before_message, now)
    else
      :ok
    end
  end

  @doc "Returns a Signal's committed statement when both IDs name the same Conversation."
  def message_for_signal(%{message_id: id, conversation_id: conversation_id})
      when is_binary(id) and is_binary(conversation_id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, conversation_id} <- Ecto.UUID.cast(conversation_id) do
      Repo.get_by(Message, id: id, conversation_id: conversation_id)
    else
      _ -> nil
    end
  end

  def message_for_signal(_event), do: nil

  @doc "Returns the latest reply candidate text for each requested Signal."
  @spec reply_candidate_texts([String.t()]) :: %{String.t() => String.t() | nil}
  def reply_candidate_texts([]), do: %{}

  def reply_candidate_texts(signal_ids) when is_list(signal_ids) do
    messages =
      Repo.all(
        from message in Message,
          where: message.signal_id in ^signal_ids,
          distinct: message.signal_id,
          order_by: [asc: message.signal_id, desc: message.created_at],
          select: {message.signal_id, message.text}
      )
      |> Map.new()

    fallback_ids = Enum.filter(signal_ids, &is_nil(Map.get(messages, &1)))

    fallback =
      if fallback_ids == [] do
        %{}
      else
        Repo.all(
          from intent in Ankole.Conversations.Delivery.Intent,
            where: intent.source_signal_id in ^fallback_ids,
            where: not is_nil(intent.fallback_visible_text),
            distinct: intent.source_signal_id,
            order_by: [asc: intent.source_signal_id, desc: intent.inserted_at],
            select: {intent.source_signal_id, intent.fallback_visible_text}
        )
        |> Map.new()
      end

    Map.new(signal_ids, &{&1, Map.get(messages, &1) || Map.get(fallback, &1)})
  end

  def agents do
    Repo.all(
      from p in Principal,
        where: p.type == :agent and p.status == :active,
        order_by: [asc: p.display_name, asc: p.uid]
    )
  end

  def model_preferences(human_uid, id) do
    with {:ok, id} <- cast_id(id),
         %Conversation{} = conversation <- Repo.one(visible_conversation(human_uid, id)),
         %Principal{} = agent <- conversation_agent(Repo, id),
         :ok <- authorize_page(human_uid, conversation.page_id) do
      ModelPreferences.selection(Repo, conversation, agent.uid)
    else
      {:error, _} = error -> error
      _ -> {:error, :conversation_not_found}
    end
  end

  def set_model_profile(human_uid, id, profile) do
    with {:ok, id} <- cast_id(id),
         %Conversation{} <- Repo.one(visible_conversation(human_uid, id)),
         %Principal{} = selected_agent <- conversation_agent(Repo, id) do
      Repo.transact(fn repo ->
        with :ok <-
               Signals.lock_target_in_tx(repo, %{
                 agent_uid: selected_agent.uid,
                 session_id: Ankole.Sessions.Key.conversation(id)
               }),
             :ok <- check_human_in_tx(repo, human_uid),
             {:ok, agent} <- active_agent_in_tx(repo, selected_agent.uid),
             %Conversation{} = conversation <-
               repo.one(from c in visible_conversation(human_uid, id), lock: "FOR UPDATE"),
             :ok <- authorize_page(human_uid, conversation.page_id),
             {:ok, profile} <- ModelPreferences.validate(agent.uid, profile),
             {:ok, conversation} <- ModelPreferences.put(repo, conversation, profile) do
          ModelPreferences.selection(repo, conversation, agent.uid)
        else
          {:error, _} = error -> error
          _ -> {:error, :conversation_not_found}
        end
      end)
    else
      {:error, _} = error -> error
      _ -> {:error, :conversation_not_found}
    end
  end

  def list(human_uid) do
    list_query(human_uid) |> Repo.all()
  end

  @doc "Lists the current Human's conversations attached to an accessible Page."
  def list_for_page(human_uid, page_id) do
    with {:ok, page_id} <- cast_id(page_id),
         :ok <- authorize_page(human_uid, page_id) do
      {:ok, Repo.all(from c in list_query(human_uid), where: c.page_id == ^page_id)}
    end
  end

  defp list_query(human_uid) do
    from c in visible_conversations(human_uid),
      join: member in Participant,
      on: member.conversation_id == c.id and member.role == :agent,
      join: agent in Principal,
      on: agent.uid == member.principal_uid,
      order_by: [desc: c.last_activity_at, desc: c.id],
      limit: 100,
      select: %{conversation: c, agent: agent}
  end

  def get(human_uid, id, opts \\ []) do
    before = Keyword.get(opts, :before_seq)
    loaded_first = Keyword.get(opts, :loaded_first_seq)

    with true <- is_nil(before) or (is_integer(before) and before > 0),
         true <- is_nil(loaded_first) or (is_integer(loaded_first) and loaded_first > 0),
         {:ok, id} <- cast_id(id) do
      Repo.transact(fn repo ->
        with %Principal{} = agent <- conversation_agent(repo, id),
             :ok <-
               Signals.lock_target_in_tx(repo, %{
                 agent_uid: agent.uid,
                 session_id: Ankole.Sessions.Key.conversation(id)
               }),
             %Conversation{} = conversation <- repo.one(visible_conversation(human_uid, id)) do
          {:ok, detail(conversation, agent, opts)}
        else
          _ -> {:error, :conversation_not_found}
        end
      end)
    else
      false -> {:error, :invalid_request}
      {:error, _} = error -> error
    end
  end

  def create(human_uid, attrs) do
    Repo.assert_outside_transaction!()
    Repo.transact(&create_in_tx(&1, human_uid, attrs)) |> committed(human_uid)
  end

  @doc "Creates a native conversation and returns publication facts to its transaction owner."
  def create_in_tx(repo, human_uid, attrs) when is_map(attrs) do
    with :ok <- Repo.require_transaction(repo),
         {:ok, id} <- cast_id(Ankole.Attrs.get(attrs, :conversation_id)),
         {:ok, message_id} <- cast_id(Ankole.Attrs.get(attrs, :message_id)),
         {:ok, mode} <- delivery_mode(Ankole.Attrs.get(attrs, :delivery_mode)),
         {:ok, page_id} <- optional_page_id(Ankole.Attrs.get(attrs, :page_id)),
         agent_uid when is_binary(agent_uid) and agent_uid != "" <-
           Ankole.Attrs.get(attrs, :agent_uid) do
      session_id = Ankole.Sessions.Key.conversation(id)
      :ok = Signals.lock_target_in_tx(repo, %{agent_uid: agent_uid, session_id: session_id})

      with :ok <- check_human_in_tx(repo, human_uid),
           {:ok, text, attachments} <- human_content(repo, human_uid, id, message_id, attrs),
           :ok <- authorize_page(human_uid, page_id),
           {:ok, agent} <- active_agent_in_tx(repo, agent_uid),
           {:ok, conversation} <-
             ensure_conversation_in_tx(
               repo,
               human_uid,
               agent,
               id,
               conversation_title(text, attachments),
               page_id
             ),
           {:ok, conversation} <-
             ModelPreferences.initialize(
               repo,
               conversation,
               agent.uid,
               Ankole.Attrs.get(attrs, :model_profile)
             ),
           {:ok, message, inserted?} <-
             append_human_message_in_tx(
               repo,
               conversation,
               human_uid,
               message_id,
               text,
               attachments
             ),
           true <- message.seq == 1,
           :ok <- ModelPreferences.authorize_input(repo, conversation, agent.uid, mode, inserted?),
           {:ok, event} <- accept_message_in_tx(repo, conversation, agent, message, mode) do
        {:ok,
         %{
           id: id,
           event: event,
           session_key: %{agent_uid: agent.uid, session_id: session_id},
           inserted?: inserted?,
           publications: publications(id, inserted?)
         }}
      else
        {:error, _} = error -> error
        _ -> {:error, :conversation_conflict}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_request}
    end
  end

  def create_in_tx(_repo, _human_uid, _attrs), do: {:error, :invalid_request}

  def post(human_uid, id, attrs) do
    Repo.assert_outside_transaction!()
    Repo.transact(&post_in_tx(&1, human_uid, id, attrs)) |> committed(human_uid)
  end

  @doc "Changes only native follow-ups that have not been admitted to a turn."
  def update_queue(human_uid, id, attrs) when is_map(attrs) do
    Repo.assert_outside_transaction!()

    Repo.transact(fn repo ->
      with {:ok, id} <- cast_id(id),
           %Conversation{} = visible <- Repo.one(visible_conversation(human_uid, id)),
           %Principal{} = agent <- conversation_agent(repo, id),
           session_id = Ankole.Sessions.Key.conversation(id),
           :ok <-
             Signals.lock_target_in_tx(repo, %{
               agent_uid: agent.uid,
               session_id: session_id
             }),
           :ok <- check_human_in_tx(repo, human_uid),
           :ok <- authorize_page(human_uid, visible.page_id),
           %Conversation{} = conversation <-
             repo.one(from c in visible_conversation(human_uid, id), lock: "FOR UPDATE"),
           inputs = repo.all(pending_query(id) |> lock("FOR UPDATE")),
           true <- Enum.all?(inputs, &(&1.human_uid == human_uid)),
           {:ok, accepted_retry} <- accepted_retry_in_tx(repo, conversation, agent, attrs),
           :ok <-
             if(accepted_retry, do: :ok, else: check_queue_version(conversation, inputs, attrs)),
           {:ok, changed} <-
             if(accepted_retry,
               do: {:ok, [accepted_retry]},
               else: change_queue_in_tx(repo, human_uid, conversation, agent, inputs, attrs)
             ),
           :ok <-
             Ankole.Sessions.Jobs.EnsureDriver.enqueue_in_tx(
               repo,
               %{agent_uid: agent.uid, session_id: session_id},
               DateTime.utc_now(:microsecond)
             ) do
        removed_ids = for input <- changed, input.data["removed"] == true, do: input.message_id

        {:ok,
         %{
           id: id,
           session_key: %{agent_uid: agent.uid, session_id: session_id},
           publications: publications(id, true),
           removed_message_ids: removed_ids
         }}
      else
        nil -> {:error, :conversation_not_found}
        false -> {:error, :invalid_request}
        error -> error
      end
    end)
    |> committed(human_uid)
  end

  def update_queue(_human_uid, _id, _attrs), do: {:error, :invalid_request}

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

  defp check_queue_version(conversation, inputs, attrs) do
    if Ankole.Attrs.get(attrs, :action) == "stop" or
         Ankole.Attrs.get(attrs, :expected_version) == queue_version(conversation, inputs),
       do: :ok,
       else: {:error, :queue_changed}
  end

  defp change_queue_in_tx(repo, human_uid, conversation, agent, inputs, attrs) do
    case Ankole.Attrs.get(attrs, :action) do
      "stop" ->
        stop_queue_in_tx(repo, human_uid, conversation, agent, inputs, attrs)

      "resume" ->
        with {:ok, _} <- put_queue_pause(repo, conversation, false), do: {:ok, []}

      "reorder" ->
        reorder_inputs_in_tx(repo, inputs, Ankole.Attrs.get(attrs, :message_ids))

      action when action in ["regenerate", "edit_last"] ->
        retry_last_in_tx(repo, human_uid, conversation, agent, action, attrs)

      action when action in ["edit", "send_now", "remove"] ->
        with {:ok, id} <- cast_id(Ankole.Attrs.get(attrs, :message_id)),
             %Signal{} = input <-
               Enum.find(inputs, &(&1.message_id == id and &1.human_uid == human_uid)) do
          with {:ok, changed} <- change_input_in_tx(repo, input, action, attrs) do
            if action == "send_now",
              do:
                reorder_inputs_in_tx(repo, inputs, [
                  id | Enum.map(inputs, & &1.message_id) -- [id]
                ]),
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

  defp accepted_retry_in_tx(repo, conversation, agent, attrs) do
    action = Ankole.Attrs.get(attrs, :action)

    if action in ["regenerate", "edit_last"] do
      with {:ok, command_id} <- cast_id(Ankole.Attrs.get(attrs, :command_id)),
           {:ok, message_id} <- cast_id(Ankole.Attrs.get(attrs, :message_id)) do
        data = retry_command_data(action, message_id, attrs)

        case repo.get_by(Signal,
               agent_uid: agent.uid,
               source: "native-control:" <> conversation.id,
               source_event_id: command_id
             ) do
          %Signal{type: "command.retry", completed_at: %DateTime{}} = existing ->
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

  defp retry_last_in_tx(repo, human_uid, conversation, agent, action, attrs) do
    with {:ok, command_id} <- cast_id(Ankole.Attrs.get(attrs, :command_id)),
         {:ok, message_id} <- cast_id(Ankole.Attrs.get(attrs, :message_id)) do
      key = %{agent_uid: agent.uid, session_id: Ankole.Sessions.Key.conversation(conversation.id)}
      now = DateTime.utc_now(:microsecond)

      with %Message{} = message <-
             repo.get_by(Message, id: message_id, conversation_id: conversation.id),
           %Signal{} = input <- retry_input(repo, human_uid, message, action),
           {:ok, command} <-
             Signals.accept_in_tx(repo, %{
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
             Ankole.Sessions.Commands.retry_source_in_tx(repo, key, command, input.id),
           :ok <- ModelPreferences.authorize_input(repo, conversation, agent.uid, "queue", true),
           :ok <- edit_last_in_tx(repo, input, message, action, attrs),
           {:ok, retry} <- Ankole.Sessions.Commands.retry_in_tx(repo, key, command, now),
           {:ok, retry} <-
             retry
             |> Signal.changeset(%{
               data: Map.put(retry.data, "model_profile", ModelPreferences.logical(conversation))
             })
             |> repo.update(),
           :ok <- remove_native_reply_in_tx(repo, conversation.id, input.id, now) do
        {:ok, [retry]}
      else
        {:ok, :target_unavailable} -> {:error, :reply_unavailable}
        nil -> {:error, :reply_unavailable}
        error -> error
      end
    end
  end

  defp remove_native_reply_in_tx(repo, conversation_id, signal_id, now) do
    # Native replies have no external Delivery intent. Replace their visible
    # statement while retaining independently created Pages and tool history.
    repo.all(
      from m in Message,
        where:
          m.conversation_id == ^conversation_id and m.signal_id == ^signal_id and
            m.author_type == :agent,
        lock: "FOR UPDATE"
    )
    |> Enum.reduce_while(:ok, fn message, :ok ->
      with :ok <- message_changed_in_tx(repo, message, nil, now),
           {:ok, _} <- repo.delete(message) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp retry_input(
         repo,
         human_uid,
         %Message{author_type: :human, author_uid: human_uid} = message,
         "edit_last"
       ) do
    repo.one(
      from s in Signal,
        where:
          s.message_id == ^message.id and s.conversation_id == ^message.conversation_id and
            s.type == "conversation.message.addressed",
        order_by: [desc: s.queue_sequence],
        limit: 1,
        lock: "FOR UPDATE"
    )
  end

  defp retry_input(
         repo,
         _human_uid,
         %Message{author_type: :agent, signal_id: signal_id} = message,
         "regenerate"
       )
       when not is_nil(signal_id) do
    case Ankole.Signals.lock_signal_in_tx(repo, signal_id) do
      %Signal{} = input -> if retryable_reply?(message, input), do: input
      nil -> nil
    end
  end

  defp retry_input(_repo, _human_uid, _message, _action), do: nil

  defp edit_last_in_tx(_repo, _input, _message, "regenerate", _attrs), do: :ok

  defp edit_last_in_tx(repo, _input, message, "edit_last", attrs) do
    if Ankole.Attrs.get(attrs, :expected_text) == (message.text || "") do
      with {:ok, text} <- native_text(Ankole.Attrs.get(attrs, :text), message.attachments),
           {:ok, updated} <-
             repo.update(Message.changeset(message, %{text: text, links: page_links(text)})),
           :ok <- message_changed_in_tx(repo, message, updated, DateTime.utc_now(:microsecond)),
           do: :ok
    else
      {:error, :queue_changed}
    end
  end

  defp put_queue_pause(repo, conversation, paused, command_id \\ nil) do
    metadata = Map.put(conversation.metadata, "queue_paused", paused)

    metadata =
      if command_id, do: Map.put(metadata, "queue_pause_command_id", command_id), else: metadata

    repo.update(
      Conversation.changeset(conversation, %{
        metadata: metadata
      })
    )
  end

  defp stop_queue_in_tx(repo, human_uid, conversation, agent, inputs, attrs) do
    with {:ok, command_id} <- cast_id(Ankole.Attrs.get(attrs, :command_id)) do
      source = "native-control:" <> conversation.id

      case repo.get_by(Signal, agent_uid: agent.uid, source: source, source_event_id: command_id) do
        %Signal{} = existing ->
          {:ok, [existing]}

        nil ->
          with {:ok, paused} <- pause_inputs_in_tx(repo, inputs),
               {:ok, _} <- put_queue_pause(repo, conversation, true, command_id),
               {:ok, event} <-
                 Signals.accept_in_tx(repo, %{
                   producer: :kernel,
                   source: source,
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

  defp pause_inputs_in_tx(repo, inputs) do
    Enum.reduce_while(inputs, {:ok, []}, fn input, {:ok, paused} ->
      case repo.update(
             Signal.changeset(input, %{data: Map.put(input.data, "delivery_mode", "queue")})
           ) do
        {:ok, input} -> {:cont, {:ok, [input | paused]}}
        error -> {:halt, error}
      end
    end)
  end

  defp change_input_in_tx(repo, input, "edit", attrs) do
    with %Message{} = message <- repo.get_by(Message, id: input.message_id),
         {:ok, text} <- native_text(Ankole.Attrs.get(attrs, :text), message.attachments),
         {:ok, updated} <-
           repo.update(Message.changeset(message, %{text: text, links: page_links(text)})),
         :ok <- message_changed_in_tx(repo, message, updated, DateTime.utc_now(:microsecond)),
         {:ok, input} <-
           repo.update(Signal.changeset(input, %{data: put_input_text(input.data, text)})),
         do: {:ok, [input]}
  end

  defp change_input_in_tx(repo, input, "send_now", _attrs) do
    with :ok <-
           Ankole.Conversations.ModelPreferences.ensure_can_steer(
             repo,
             input.agent_uid,
             input.conversation_id,
             input.data["model_profile"] || "primary"
           ),
         {:ok, input} <-
           repo.update(
             Signal.changeset(input, %{data: Map.put(input.data, "delivery_mode", "steer")})
           ),
         do: {:ok, [input]}
  end

  defp change_input_in_tx(repo, input, "remove", _attrs) do
    # Retain the accepted identity so a late POST retry cannot recreate removed input.
    now = DateTime.utc_now(:microsecond)

    with %Message{} = message <- repo.get_by(Message, id: input.message_id),
         :ok <- message_changed_in_tx(repo, message, nil, now),
         {:ok, input} <-
           repo.update(
             Signal.changeset(input, %{
               completed_at: now,
               data: Map.put(input.data, "removed", true)
             })
           ),
         do: {:ok, [input]}
  end

  defp put_input_text(data, text) do
    data = Map.put(data, "text", text)
    if is_map(data["entry"]), do: put_in(data, ["entry", "text"], text), else: data
  end

  defp reorder_inputs_in_tx(repo, inputs, ids) when is_list(ids) do
    current_ids = Enum.map(inputs, & &1.message_id)

    if length(ids) == length(current_ids) and MapSet.new(ids) == MapSet.new(current_ids) do
      by_id = Map.new(inputs, &{&1.message_id, &1})
      # Allocate above the high-water mark to preserve the unique sequence constraint.
      maximum =
        case inputs do
          [input | _] ->
            repo.one(
              from s in Signal,
                where: s.agent_uid == ^input.agent_uid and s.session_id == ^input.session_id,
                select: max(s.queue_sequence)
            )

          [] ->
            0
        end

      ids
      |> Enum.with_index((maximum || 0) + 1)
      |> Enum.reduce_while({:ok, []}, fn {id, sequence}, {:ok, changed} ->
        case repo.update(Signal.changeset(Map.fetch!(by_id, id), %{queue_sequence: sequence})) do
          {:ok, input} -> {:cont, {:ok, [input | changed]}}
          error -> {:halt, error}
        end
      end)
    else
      {:error, :queue_changed}
    end
  end

  defp reorder_inputs_in_tx(_repo, _inputs, _ids), do: {:error, :invalid_request}

  @doc "Deletes an idle native conversation owned by the current Human. Pages remain independent."
  def delete(human_uid, id) do
    Repo.assert_outside_transaction!()

    result =
      Repo.transact(fn repo ->
        with {:ok, id} <- cast_id(id),
             {:ok, %{agent: agent}} <- get(human_uid, id),
             :ok <-
               Signals.lock_target_in_tx(repo, %{
                 agent_uid: agent.uid,
                 session_id: Ankole.Sessions.Key.conversation(id)
               }),
             %Conversation{kind: :native, created_by: ^human_uid} = conversation <-
               repo.one(from c in Conversation, where: c.id == ^id, lock: "FOR UPDATE"),
             false <-
               repo.exists?(
                 from signal in Ankole.Signals.Signal,
                   where:
                     (signal.conversation_id == ^id or
                        signal.session_id == ^Ankole.Sessions.Key.conversation(id)) and
                       signal.input_state == "open" and is_nil(signal.completed_at)
               ),
             {:ok, _} <-
               AIGateway.end_active_conversation_in_tx(
                 repo,
                 agent.uid,
                 Ankole.Sessions.Key.conversation(id),
                 DateTime.utc_now(:microsecond)
               ),
             {:ok, _} <- repo.delete(conversation) do
          {:ok, id}
        else
          true -> {:error, :conversation_busy}
          {:error, _} = error -> error
          _ -> {:error, :conversation_not_found}
        end
      end)

    case result do
      {:ok, id} ->
        Ankole.Conversations.Events.publish_status(id)
        {:ok, id}

      error ->
        error
    end
  end

  @doc "Appends human input and returns publication facts to its transaction owner."
  def post_in_tx(repo, human_uid, id, attrs) when is_map(attrs) do
    with :ok <- Repo.require_transaction(repo),
         {:ok, id} <- cast_id(id),
         {:ok, message_id} <- cast_id(Ankole.Attrs.get(attrs, :message_id)),
         {:ok, mode} <- delivery_mode(Ankole.Attrs.get(attrs, :delivery_mode)),
         %Conversation{} <- repo.one(visible_conversation(human_uid, id)),
         %Principal{} = agent <- conversation_agent(repo, id) do
      :ok =
        Signals.lock_target_in_tx(repo, %{
          agent_uid: agent.uid,
          session_id: Ankole.Sessions.Key.conversation(id)
        })

      with :ok <- check_human_in_tx(repo, human_uid),
           {:ok, text, attachments} <- human_content(repo, human_uid, id, message_id, attrs),
           {:ok, agent} <- active_agent_in_tx(repo, agent.uid),
           %Conversation{} = conversation <-
             repo.one(from c in visible_conversation(human_uid, id), lock: "FOR UPDATE"),
           :ok <- authorize_page(human_uid, conversation.page_id),
           {:ok, message, inserted?} <-
             append_human_message_in_tx(
               repo,
               conversation,
               human_uid,
               message_id,
               text,
               attachments
             ),
           :ok <- ModelPreferences.authorize_input(repo, conversation, agent.uid, mode, inserted?),
           {:ok, event} <- accept_message_in_tx(repo, conversation, agent, message, mode) do
        {:ok,
         %{
           id: id,
           event: event,
           session_key: %{agent_uid: event.agent_uid, session_id: event.session_id},
           inserted?: inserted?,
           publications: publications(id, inserted?)
         }}
      else
        {:error, _} = error -> error
        _ -> {:error, :conversation_not_found}
      end
    else
      nil -> {:error, :conversation_not_found}
      error -> error
    end
  end

  def post_in_tx(_repo, _human_uid, _id, _attrs), do: {:error, :invalid_request}

  @doc "Commits a statement to its native host or external Delivery destination."
  def post_in_tx(
        repo,
        %StatementTarget{kind: :external} = target,
        %Ankole.Conversations.Statement{} = statement
      ),
      do: Ankole.Conversations.Delivery.Posting.post_in_tx(repo, target, statement)

  def post_in_tx(
        repo,
        %StatementTarget{kind: :native} = target,
        %Ankole.Conversations.Statement{} = statement
      ) do
    text = Ankole.Conversations.Statement.text(statement)
    kind = if statement.notice, do: :notice, else: :message

    attachments =
      if is_map(statement.completion),
        do: Map.get(statement.completion, :attachments, []),
        else: []

    with {:ok, attachments} <-
           Ankole.Conversations.Delivery.Attachment.normalize_attachments(attachments) do
      if text in [nil, ""] and attachments == [] do
        {:ok, %Ankole.Conversations.PostResult{}}
      else
        with {:ok, message} <-
               post_native_in_tx(
                 repo,
                 target.conversation_id,
                 statement.signal,
                 text,
                 kind,
                 attachments
               ),
             do: {:ok, %Ankole.Conversations.PostResult{messages: [message]}}
      end
    end
  end

  defp post_native_in_tx(repo, id, event, text, kind, attachments) do
    with {:ok, id} <- cast_id(id),
         {:ok, text} <- native_text(text, attachments),
         %Conversation{kind: :native} = conversation <-
           repo.one(from c in Conversation, where: c.id == ^id, lock: "FOR UPDATE"),
         %Principal{uid: uid} <- conversation_agent(repo, id),
         true <- uid == event.agent_uid do
      case repo.get_by(Message, conversation_id: id, signal_id: event.id) do
        %Message{text: ^text, kind: ^kind, attachments: ^attachments} = message ->
          {:ok, message}

        %Message{} ->
          {:error, :conversation_conflict}

        nil ->
          with :ok <-
                 Ankole.Conversations.Delivery.Attachment.verify_in_drive(
                   event.agent_uid,
                   attachments
                 ),
               :ok <-
                 Ankole.Files.reference_contents_in_tx(
                   repo,
                   Enum.map(attachments, & &1["blob_ref"])
                 ),
               {:ok, seq} <- next_sequence_in_tx(repo, conversation) do
            attrs = %{
              id: Ankole.Ecto.UUIDv7.autogenerate(),
              conversation_id: id,
              seq: seq,
              author_type: :agent,
              author_uid: uid,
              kind: kind,
              text: text,
              attachments: attachments,
              links: page_links(text),
              origin: :native,
              session_id: event.session_id,
              signal_id: event.id,
              reply_to_message_id:
                if(is_map(event.data) and event.data["conversation_id"] == id,
                  do: event.message_id
                ),
              created_at: DateTime.utc_now(:microsecond)
            }

            with {:ok, message} <- %Message{} |> Message.changeset(attrs) |> repo.insert(),
                 {:ok, _} <- touch_in_tx(repo, conversation, message.created_at) do
              {:ok, message}
            end
          end
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :conversation_not_found}
    end
  end

  @doc "Returns the native host IDs for model-history lifecycle queries."
  def native_ids_query, do: from(c in Conversation, where: c.kind == :native, select: c.id)

  @doc "The retained Message identities withdrawn from public conversation facts."
  def removed_message_ids_query(conversation_id \\ nil) do
    query =
      from input in Signal,
        where: input.data["removed"] == true and not is_nil(input.message_id),
        select: input.message_id

    if is_nil(conversation_id),
      do: query,
      else: from(input in query, where: input.conversation_id == ^conversation_id)
  end

  @doc "Reads a bounded snapshot of statements not yet included by the caller."
  def context_snapshot(
        id,
        %{agent_uid: agent_uid, session_id: session_id},
        read_seq,
        excluded_ids,
        opts \\ []
      ) do
    limit = min(max(Keyword.get(opts, :limit, 50), 1), 500)

    Repo.transact(fn repo ->
      with {:ok, id} <- cast_id(id),
           %Conversation{} = conversation <-
             repo.one(from c in Conversation, where: c.id == ^id, lock: "FOR SHARE") do
        max_seq = conversation.sequence_high_water

        withheld =
          from input in Signal,
            where: input.conversation_id == ^id and not is_nil(input.message_id),
            where:
              input.producer == :kernel and input.type == "conversation.message.addressed" and
                input.input_state == "open" and is_nil(input.last_attempt_at) and
                is_nil(input.completed_at),
            select: input.message_id

        messages =
          repo.all(
            from m in Message,
              where:
                m.conversation_id == ^id and m.seq > ^read_seq and
                  m.seq <= ^max_seq,
              where:
                is_nil(m.session_id) or m.session_id != ^session_id or is_nil(m.author_uid) or
                  m.author_uid != ^agent_uid,
              where: m.id not in ^excluded_ids,
              where: m.id not in subquery(withheld),
              where: m.id not in subquery(removed_message_ids_query(id)),
              order_by: [desc: m.seq],
              limit: ^limit
          )
          |> Enum.reverse()

        {:ok, %{messages: messages, max_seq: max_seq}}
      else
        {:error, _} = error -> error
        _ -> {:error, :conversation_not_found}
      end
    end)
  end

  @doc false
  def ids_for_agent_in_tx(repo, uid) do
    repo.all(
      from c in Conversation,
        join: p in Participant,
        on: p.conversation_id == c.id,
        where: c.kind == :native and p.principal_uid == ^uid and p.role == :agent,
        select: c.id
    )
  end

  @doc false
  def delete_for_agent_in_tx(repo, uid) do
    ids =
      from p in Participant,
        where: p.principal_uid == ^uid and p.role == :agent,
        select: p.conversation_id

    repo.delete_all(from c in Conversation, where: c.kind == :native and c.id in subquery(ids))
    :ok
  end

  defp publications(id, true), do: [{id, :message}]
  defp publications(_id, false), do: []

  defp committed({:ok, %{id: id, publications: publications} = result}, human_uid) do
    Ankole.Conversations.Events.publish_committed(publications)

    if publications != [] do
      key = result.session_key
      Ankole.Sessions.Events.publish_status(key.agent_uid, key.session_id)
    end

    get(human_uid, id, removed_message_ids: Map.get(result, :removed_message_ids, []))
  end

  defp committed({:error, _} = error, _human_uid), do: error

  defp ensure_conversation_in_tx(repo, human_uid, agent, id, text, page_id) do
    attrs = %{
      id: id,
      kind: :native,
      title: text |> String.trim() |> String.split("\n", parts: 2) |> hd() |> String.slice(0, 80),
      created_by: human_uid,
      page_id: page_id,
      last_activity_at: DateTime.utc_now(:microsecond)
    }

    with :ok <- available_native_id(repo, agent.uid, id),
         {:ok, _} <-
           %Conversation{}
           |> Conversation.changeset(attrs)
           |> repo.insert(on_conflict: :nothing, conflict_target: [:tenant_id, :id]),
         %Conversation{created_by: ^human_uid, page_id: ^page_id} = conversation <-
           repo.one(from c in Conversation, where: c.id == ^id, lock: "FOR UPDATE"),
         :ok <- check_existing_agent(repo, id, agent.uid),
         {:ok, _} <- insert_participant(repo, id, human_uid, :owner),
         {:ok, _} <- insert_participant(repo, id, agent.uid, :agent),
         %Principal{uid: uid} <- conversation_agent(repo, id),
         true <- uid == agent.uid,
         {:ok, _} <-
           AIGateway.ensure_conversation_in_tx(
             repo,
             agent.uid,
             Ankole.Sessions.Key.conversation(id)
           ) do
      {:ok, conversation}
    else
      {:error, _} = error -> error
      _ -> {:error, :conversation_conflict}
    end
  end

  defp available_native_id(repo, agent_uid, id) do
    session_id = Ankole.Sessions.Key.conversation(id)
    exists? = repo.exists?(from c in Conversation, where: c.id == ^id)

    used? =
      AIGateway.conversation_exists_by_key?(repo, agent_uid, session_id) or
        repo.exists?(
          from s in Ankole.Signals.Signal,
            where: s.agent_uid == ^agent_uid and s.session_id == ^session_id
        )

    if exists? or not used?, do: :ok, else: {:error, :conversation_conflict}
  end

  defp insert_participant(repo, id, uid, role) do
    %Participant{}
    |> Participant.changeset(%{conversation_id: id, principal_uid: uid, role: role})
    |> repo.insert(
      on_conflict: :nothing,
      conflict_target: [:tenant_id, :conversation_id, :principal_uid]
    )
  end

  defp optional_page_id(nil), do: {:ok, nil}
  defp optional_page_id(id), do: cast_id(id)

  defp authorize_page(_uid, nil), do: :ok

  defp authorize_page(uid, id) do
    case Ankole.Pod.Pages.authorize(uid, id, "page_view") do
      {:ok, _} -> :ok
      _ -> {:error, :page_unavailable}
    end
  end

  defp check_existing_agent(repo, id, uid) do
    case conversation_agent(repo, id) do
      nil -> :ok
      %Principal{uid: ^uid} -> :ok
      _ -> {:error, :conversation_conflict}
    end
  end

  defp human_content(repo, uid, conversation_id, message_id, attrs) do
    existing =
      repo.get_by(Message, id: message_id, conversation_id: conversation_id, author_uid: uid)

    with {:ok, attachments} <-
           Ankole.Conversations.Attachments.Native.resolve(
             uid,
             Ankole.Attrs.get(attrs, :attachments),
             if(existing, do: existing.attachments, else: [])
           ),
         {:ok, text} <- native_text(Ankole.Attrs.get(attrs, :text), attachments) do
      {:ok, text, attachments}
    end
  end

  defp conversation_title(text, attachments),
    do: text || hd(attachments)["name"]

  defp append_human_message_in_tx(repo, conversation, human_uid, id, text, attachments) do
    existing = repo.get_by(Message, id: id)

    attachments =
      Ankole.Conversations.Attachments.prepare_native_in_tx(
        repo,
        conversation.id,
        id,
        attachments,
        if(existing, do: existing.attachments, else: [])
      )

    case existing do
      %Message{
        conversation_id: conversation_id,
        author_uid: ^human_uid,
        text: ^text,
        attachments: ^attachments,
        author_type: :human,
        kind: :message
      } = message
      when conversation_id == conversation.id ->
        {:ok, message, false}

      %Message{} ->
        {:error, :conversation_conflict}

      nil ->
        with :ok <-
               Ankole.Files.reference_contents_in_tx(
                 repo,
                 Enum.map(attachments, & &1["blob_ref"])
               ),
             {:ok, seq} <- next_sequence_in_tx(repo, conversation) do
          attrs = %{
            id: id,
            conversation_id: conversation.id,
            seq: seq,
            author_type: :human,
            author_uid: human_uid,
            kind: :message,
            text: text,
            attachments: attachments,
            links: page_links(text),
            origin: :native,
            created_at: DateTime.utc_now(:microsecond)
          }

          with {:ok, _} <-
                 %Message{}
                 |> Message.changeset(attrs)
                 |> repo.insert(on_conflict: :nothing, conflict_target: [:tenant_id, :id]),
               %Message{
                 conversation_id: conversation_id,
                 author_uid: ^human_uid,
                 text: ^text,
                 attachments: ^attachments,
                 author_type: :human,
                 kind: :message
               } = message <- repo.get_by(Message, id: id),
               true <- conversation_id == conversation.id,
               {:ok, _} <- touch_in_tx(repo, conversation, message.created_at) do
            {:ok, message, true}
          else
            {:error, _} = error -> error
            _ -> {:error, :conversation_conflict}
          end
        end
    end
  end

  defp accept_message_in_tx(repo, conversation, agent, message, mode) do
    data = %{
      "conversation_id" => conversation.id,
      "message_id" => message.id,
      "message_ids" => [message.id],
      "author_uid" => message.author_uid,
      "text" => message.text,
      "model_profile" => ModelPreferences.logical(conversation)
    }

    data = if mode == "queue", do: Map.put(data, "delivery_mode", mode), else: data

    data =
      if message.attachments == [],
        do: data,
        else:
          Map.put(data, "entry", %{"text" => message.text, "attachments" => message.attachments})

    Signals.accept_in_tx(repo, %{
      producer: :kernel,
      source: Ankole.Sessions.Key.conversation(conversation.id),
      id: message.id,
      type: "conversation.message.addressed",
      subject: conversation.id,
      target: %{agent_uid: agent.uid, conversation_id: conversation.id},
      sender: message.author_uid,
      message_id: message.id,
      time: message.created_at,
      data: data
    })
  end

  defp delivery_mode(nil), do: {:ok, "steer"}
  defp delivery_mode(mode) when mode in ["steer", "queue"], do: {:ok, mode}
  defp delivery_mode(_mode), do: {:error, :invalid_request}

  defp pending_query(conversation_id) do
    from input in Signal,
      where:
        input.conversation_id == ^conversation_id and
          input.type == "conversation.message.addressed" and
          input.input_state == "open" and is_nil(input.completed_at) and
          is_nil(input.last_attempt_at),
      order_by: [asc: input.queue_sequence]
  end

  @doc "Allocates one committed statement sequence in the caller's transaction."
  def next_sequence_in_tx(repo, %Conversation{id: id}) do
    case repo.one(from c in Conversation, where: c.id == ^id, lock: "FOR UPDATE") do
      %Conversation{} = conversation ->
        seq = conversation.sequence_high_water + 1

        with {:ok, _} <-
               conversation |> Ecto.Changeset.change(sequence_high_water: seq) |> repo.update(),
             do: {:ok, seq}

      nil ->
        {:error, :conversation_not_found}
    end
  end

  defp touch_in_tx(repo, conversation, now) do
    conversation |> Ecto.Changeset.change(last_activity_at: now) |> repo.update()
  end

  defp check_human_in_tx(repo, human_uid) do
    case repo.get_by(Principal, uid: human_uid, type: :human, status: :active) do
      %Principal{} -> WorkAccess.check_in_tx(repo, WorkAccess.from_sender(repo, human_uid))
      _ -> {:error, :invalid_request}
    end
  end

  defp active_agent_in_tx(repo, agent_uid) do
    case repo.one(from p in Principal, where: p.uid == ^agent_uid, lock: "FOR UPDATE") do
      %Principal{type: :agent, status: :active} = agent -> {:ok, agent}
      _ -> {:error, :agent_unavailable}
    end
  end

  defp visible_conversations(human_uid) do
    from c in Conversation,
      join: member in Participant,
      on: member.conversation_id == c.id and member.principal_uid == ^human_uid,
      join: human in Principal,
      on: human.uid == member.principal_uid,
      where: c.kind == :native and human.type == :human and human.status == :active
  end

  defp visible_conversation(human_uid, id),
    do: from(c in visible_conversations(human_uid), where: c.id == ^id)

  defp conversation_agent(repo, id) do
    repo.one(
      from p in Participant,
        join: agent in Principal,
        on: agent.uid == p.principal_uid,
        where: p.conversation_id == ^id and p.role == :agent,
        select: agent
    )
  end

  defp detail(conversation, agent, opts) do
    removed = removed_message_ids_query(conversation.id)

    query =
      from m in Message,
        where:
          m.conversation_id == ^conversation.id and m.seq <= ^conversation.sequence_high_water and
            m.id not in subquery(removed),
        order_by: [desc: m.seq],
        limit: 501

    query =
      case Keyword.get(opts, :before_seq) do
        nil -> query
        sequence -> from m in query, where: m.seq < ^sequence
      end

    rows = Repo.all(query)
    messages = rows |> Enum.take(500) |> Enum.reverse()
    older_before = if length(rows) > 500, do: hd(messages).seq, else: nil
    loaded_first = min(opts[:loaded_first_seq] || older_before || 1, older_before || 1)

    removed_ids =
      Repo.all(
        from m in Message,
          where:
            m.conversation_id == ^conversation.id and m.seq >= ^loaded_first and
              m.seq <= ^conversation.sequence_high_water and m.id in subquery(removed),
          select: m.id
      )
      |> Enum.concat(opts[:removed_message_ids] || [])
      |> Enum.uniq()

    model =
      AIGateway.list_active_conversations(Repo,
        subject_uid: agent.uid,
        conversation_key: Ankole.Sessions.Key.conversation(conversation.id),
        limit: 1
      )
      |> List.first()

    pending_inputs = Repo.all(pending_query(conversation.id))

    %{
      conversation: conversation,
      agent: agent,
      messages: messages,
      older_messages_before_seq: older_before,
      message_range: %{
        first_seq: older_before || 1,
        last_seq:
          min(
            (opts[:before_seq] || conversation.sequence_high_water + 1) - 1,
            conversation.sequence_high_water
          )
      },
      pending_inputs: pending_inputs,
      removed_message_ids: removed_ids,
      retryable_message_id: retryable_message_id(conversation, agent, messages, opts),
      queue_version: queue_version(conversation, pending_inputs),
      session_id: Ankole.Sessions.Key.conversation(conversation.id),
      model_conversation_id: model && model.id,
      status:
        Ankole.Sessions.status(%{
          agent_uid: agent.uid,
          session_id: Ankole.Sessions.Key.conversation(conversation.id)
        })
    }
  end

  # This is an advisory capability. The mutation repeats the same runtime
  # predicate under its session lock before it changes history.
  defp retryable_message_id(conversation, agent, messages, opts) do
    message =
      if opts[:before_seq] do
        Repo.one(
          from m in Message,
            where:
              m.conversation_id == ^conversation.id and
                m.id not in subquery(removed_message_ids_query(conversation.id)),
            order_by: [desc: m.seq],
            limit: 1
        )
      else
        List.last(messages)
      end

    case message do
      %Message{author_type: :agent, signal_id: signal_id} when not is_nil(signal_id) ->
        key = %{
          agent_uid: agent.uid,
          session_id: Ankole.Sessions.Key.conversation(conversation.id)
        }

        case Repo.transact(fn repo ->
               with {:ok, %Signal{} = input} <-
                      Ankole.Sessions.Commands.retry_source_in_tx(repo, key, nil, signal_id),
                    true <- retryable_reply?(message, input) do
                 {:ok, message.id}
               else
                 _ -> {:ok, nil}
               end
             end) do
          {:ok, id} -> id
          {:error, _} -> nil
        end

      _ ->
        nil
    end
  end

  defp retryable_reply?(%Message{kind: :message}, %Signal{}), do: true

  defp retryable_reply?(%Message{kind: :notice}, %Signal{
         input_state: "dead_letter",
         last_attempt_at: %DateTime{}
       }),
       do: true

  defp retryable_reply?(_, _), do: false

  defp cast_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :invalid_id}
    end
  end

  defp validate_text(text) when is_binary(text) do
    if String.valid?(text) and not String.contains?(text, <<0>>) and String.trim(text) != "",
      do: {:ok, text},
      else: {:error, :invalid_text}
  end

  defp validate_text(_), do: {:error, :invalid_text}

  defp native_text(nil, [_attachment | _rest]), do: {:ok, nil}

  defp native_text(text, [_attachment | _rest]) when is_binary(text) do
    if String.valid?(text) and String.trim(text) == "",
      do: {:ok, nil},
      else: validate_text(text)
  end

  defp native_text(text, _attachments), do: validate_text(text)

  defp page_links(text) when is_binary(text) do
    Regex.scan(~r/ankole:page\/([0-9a-f-]{36})(?![0-9a-f-])/, text, capture: :all_but_first)
    |> List.flatten()
    |> Enum.flat_map(fn id ->
      case Ecto.UUID.cast(id) do
        {:ok, id} -> [%{"kind" => "page", "id" => id}]
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  defp page_links(_text), do: []
end
