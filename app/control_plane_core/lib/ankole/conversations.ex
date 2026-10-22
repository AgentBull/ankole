defmodule Ankole.Conversations do
  @moduledoc """
  Owns conversations, participation, and committed messages.

  The domain gives resource-level code interface functions and one generic
  action for each transaction entry point. The `_in_tx` functions run inside
  the transaction of a generic action of this domain or of another domain.
  """
  use Ankole.Ash.Domain
  require Ash.Query

  alias Ankole.Conversations.Target, as: StatementTarget
  alias Ankole.AIGateway
  alias Ankole.Conversations.{Conversation, Locks, Message, ModelPreferences, Participant}
  alias Ankole.Conversations.Delivery.Intent
  alias Ankole.Principals.WorkAccess
  alias Ankole.Signals.Signal
  alias Ankole.{Errors, Repo, Signals}

  resources do
    resource Ankole.Conversations.Conversation do
      define(:get_conversation, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_conversations, action: :read)
      define(:ensure_native_conversation, action: :ensure_native)
      define(:create_external_conversation, action: :create_external)
      define(:observe_conversation, action: :observe)
      define(:put_metadata_conversation, action: :put_metadata)
      define(:touch_conversation, action: :touch)
      define(:advance_sequence_conversation, action: :advance_sequence)
      define(:set_standing_orders_conversation, action: :set_standing_orders)
      define(:remove_conversation, action: :remove)
      define(:start_native_conversation, action: :start_native, args: [:human_uid, :attrs])
      define(:post_native_message, action: :post_native, args: [:human_uid, :id, :attrs])

      define(:change_native_queue,
        action: :change_native_queue,
        args: [:human_uid, :id, :attrs]
      )

      define(:remove_native_conversation, action: :remove_native, args: [:human_uid, :id])
      define(:native_conversation_detail, action: :native_detail, args: [:human_uid, :id, :opts])

      define(:select_model_profile,
        action: :select_model_profile,
        args: [:human_uid, :id, :profile]
      )

      define(:update_external_metadata, action: :update_external_metadata, args: [:id, :update])
      define(:observe_entry, action: :observe_entry, args: [:binding, :fact, :now])
      define(:observe_reaction, action: :observe_reaction, args: [:binding, :fact, :now])
      define(:observe_action, action: :observe_action, args: [:binding, :fact, :now])
      define(:observe_lifecycle, action: :observe_lifecycle, args: [:binding, :fact, :now])
      define(:notify_held_sender, action: :notify_held_sender, args: [:fact, :now])

      define(:ensure_im_group,
        action: :ensure_im_group,
        args: [:group_key, :attrs, :context, :opts]
      )

      define(:update_im_group_membership,
        action: :update_im_group_membership,
        args: [:group_key, :update]
      )

      define(:replace_im_group_members,
        action: :replace_im_group_members,
        args: [:group_id, :human_uids]
      )

      define(:reconcile_im_group_agents, action: :reconcile_im_group_agents, args: [:group_id])

      define(:read_context_snapshot,
        action: :context_snapshot,
        args: [:id, :key, :read_seq, :excluded_ids, :opts]
      )
    end

    resource Ankole.Conversations.Participant do
      define(:get_participant,
        action: :read,
        get_by: [:conversation_id, :principal_uid],
        not_found_error?: false
      )

      define(:list_participants, action: :read)
      define(:join_participant, action: :join)
    end

    resource Ankole.Conversations.Message do
      define(:get_message, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_messages, action: :read)
      define(:record_message, action: :record)
      define(:record_once_message, action: :record_once)
      define(:edit_message, action: :edit)
      define(:observe_message, action: :observe)
      define(:resolve_attachments_message, action: :resolve_attachments)
      define(:remove_message, action: :remove)
    end

    resource Ankole.Conversations.ExternalMessageRef do
      define(:get_external_message_ref,
        action: :read,
        get_by: [:message_id],
        not_found_error?: false
      )

      define(:list_external_message_refs, action: :read)
      define(:record_external_message_ref, action: :record)
      define(:observe_external_message_ref, action: :observe)
      define(:fold_reaction_external_message_ref, action: :fold_reaction)
    end

    resource Ankole.Conversations.InputTombstone do
      define(:get_input_tombstone,
        action: :read,
        get_by: [:conversation_id, :provider_message_id],
        not_found_error?: false
      )

      define(:list_input_tombstones, action: :read)
      define(:record_input_tombstone, action: :record)
      define(:expire_input_tombstone, action: :expire)
    end

    resource Ankole.Conversations.InboundBatch do
      define(:get_inbound_batch, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_inbound_batches, action: :read)
      define(:open_inbound_batch, action: :open)
      define(:replace_prefix_inbound_batch, action: :replace_prefix)
      define(:revise_inbound_batch, action: :revise)
      define(:finalize_inbound_batch, action: :finalize_due, args: [:batch_id, :now])
    end

    resource Ankole.Conversations.Delivery.PreviewState do
      define(:get_preview_state, action: :read, get_by: [:signal_id], not_found_error?: false)
      define(:list_preview_states, action: :read)
      define(:ensure_preview_state, action: :ensure)
      define(:update_preview_preview_state, action: :update_preview)

      define(:record_preview_provider_message,
        action: :record_provider_message,
        args: [:signal_id, :provider_message_id, :provider_thread_id]
      )

      define(:put_preview_checkpoint,
        action: :put_checkpoint,
        args: [:signal_id, :checkpoint, :source]
      )

      define(:update_preview_checkpoint, action: :update_checkpoint, args: [:signal_id, :update])

      define(:prepare_preview_mutation,
        action: :prepare_mutation,
        args: [:signal_id, :purpose, :actions_digest, :uuid]
      )

      define(:wake_blocked_previews, action: :wake_blocked, args: [:agent_uid, :binding_name])

      define(:claim_preview_owner,
        action: :claim_owner,
        args: [:signal_id, :subject_uid, :conversation_id, :stream_signal_id, :opts]
      )

      define(:authorize_preview_owner, action: :authorize_owner, args: [:opts])
      define(:switch_preview_owner, action: :switch_owner, args: [:state, :new_owner, :handoff])

      define(:checkpoint_preview_presentation,
        action: :checkpoint_presentation,
        args: [:state, :presentation]
      )
    end

    resource Ankole.Conversations.Delivery.Intent do
      define(:get_intent,
        action: :read,
        get_by: [:agent_uid, :binding_name, :outbound_key],
        not_found_error?: false
      )

      define(:list_intents, action: :read)
      define(:commit_intent, action: :commit)
      define(:prepare_intent, action: :prepare)
      define(:import_attachments_intent, action: :import_attachments)
      define(:link_message_intent, action: :link_message)

      define(:claim_intent_dispatch,
        action: :claim_dispatch,
        args: [:agent_uid, :binding_name, :outbound_key, :adapter, :now]
      )

      define(:finalize_intent_attempt,
        action: :finalize_attempt,
        args: [:intent, :phase, :result, :conversation, :now]
      )

      define(:requeue_intent,
        action: :retry_stopped,
        args: [:agent_uid, :binding_name, :outbound_key, :now]
      )

      define(:wake_blocked_intents,
        action: :wake_blocked,
        args: [:agent_uid, :binding_name, :now]
      )
    end
  end

  @addressed "conversation.message.addressed"

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
      conversation_message(conversation_id, id)
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
      Message
      |> Ash.Query.filter(signal_id in ^signal_ids)
      |> Ash.Query.sort(created_at: :desc)
      |> Ash.Query.select([:signal_id, :text])
      |> Ankole.Ash.read!()
      |> latest_by(:signal_id, :text)

    fallback_ids = Enum.filter(signal_ids, &is_nil(Map.get(messages, &1)))

    fallback =
      if fallback_ids == [] do
        %{}
      else
        Intent
        |> Ash.Query.filter(
          source_signal_id in ^fallback_ids and not is_nil(fallback_visible_text)
        )
        |> Ash.Query.sort(inserted_at: :desc)
        |> Ash.Query.select([:source_signal_id, :fallback_visible_text])
        |> Ankole.Ash.read!()
        |> latest_by(:source_signal_id, :fallback_visible_text)
      end

    Map.new(signal_ids, &{&1, Map.get(messages, &1) || Map.get(fallback, &1)})
  end

  # The rows are sorted newest first, so the first row of each key wins.
  defp latest_by(rows, key, value) do
    Enum.reduce(rows, %{}, fn row, acc ->
      Map.put_new(acc, Map.fetch!(row, key), Map.fetch!(row, value))
    end)
  end

  def agents do
    Ankole.Principals.list_principals!(
      query: [
        filter: [type: :agent, status: :active],
        sort: [display_name: :asc, uid: :asc]
      ]
    )
  end

  @doc """
  Gives a native conversation that the active Human takes part in.

  This read takes no lock and opens no transaction, so a caller can use it in
  its own transaction. `get/3` gives the complete detail.
  """
  def visible_native_conversation(human_uid, id) do
    with {:ok, id} <- cast_id(id),
         %Conversation{} = conversation <- visible_conversation(human_uid, id) do
      {:ok, conversation}
    else
      {:error, _} = error -> error
      nil -> {:error, :conversation_not_found}
    end
  end

  def model_preferences(human_uid, id) do
    with {:ok, id} <- cast_id(id),
         %Conversation{} = conversation <- visible_conversation(human_uid, id),
         %{} = agent <- conversation_agent(id),
         :ok <- authorize_page(human_uid, conversation.page_id) do
      ModelPreferences.selection(Repo, conversation, agent.uid)
    else
      {:error, _} = error -> error
      _ -> {:error, :conversation_not_found}
    end
  end

  def set_model_profile(human_uid, id, profile),
    do: human_uid |> select_model_profile(id, profile) |> Errors.reason()

  @doc false
  def set_model_profile_in_tx(repo, human_uid, id, profile) do
    with {:ok, id} <- cast_id(id),
         %Conversation{} <- visible_conversation(human_uid, id),
         %{} = selected_agent <- conversation_agent(id) do
      with :ok <- lock_participants_in_tx(repo, human_uid, selected_agent.uid),
           :ok <-
             Signals.lock_target_in_tx(repo, %{
               agent_uid: selected_agent.uid,
               session_id: Ankole.Sessions.Key.conversation(id)
             }),
           :ok <- check_human_in_tx(repo, human_uid),
           {:ok, agent} <- active_agent_in_tx(repo, selected_agent.uid),
           %Conversation{} = conversation <- visible_conversation(human_uid, id, lock: true),
           :ok <- authorize_page(human_uid, conversation.page_id),
           {:ok, profile} <- ModelPreferences.validate(agent.uid, profile),
           {:ok, conversation} <- ModelPreferences.put(repo, conversation, profile) do
        ModelPreferences.selection(repo, conversation, agent.uid)
      else
        {:error, _} = error -> error
        _ -> {:error, :conversation_not_found}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :conversation_not_found}
    end
  end

  def list(human_uid), do: list_native(human_uid, nil)

  @doc "Lists the current Human's conversations attached to an accessible Page."
  def list_for_page(human_uid, page_id) do
    with {:ok, page_id} <- cast_id(page_id),
         :ok <- authorize_page(human_uid, page_id) do
      {:ok, list_native(human_uid, page_id)}
    end
  end

  defp list_native(human_uid, page_id) do
    if active_human?(human_uid) do
      query =
        Ash.Query.filter(
          Conversation,
          kind == :native and
            exists(Participant, conversation_id == parent(id) and principal_uid == ^human_uid) and
            exists(Participant, conversation_id == parent(id) and role == :agent)
        )

      query = if page_id, do: Ash.Query.filter(query, page_id == ^page_id), else: query

      conversations =
        query
        |> Ash.Query.sort(last_activity_at: :desc, id: :desc)
        |> Ash.Query.limit(100)
        |> Ankole.Ash.read!()

      agents = conversation_agents(Enum.map(conversations, & &1.id))

      for conversation <- conversations,
          agent = Map.get(agents, conversation.id),
          do: %{conversation: conversation, agent: agent}
    else
      []
    end
  end

  def get(human_uid, id, opts \\ []),
    do: human_uid |> native_conversation_detail(id, opts) |> Errors.reason()

  @doc false
  def detail_in_tx(repo, human_uid, id, opts) do
    before = Keyword.get(opts, :before_seq)
    loaded_first = Keyword.get(opts, :loaded_first_seq)

    with true <- is_nil(before) or (is_integer(before) and before > 0),
         true <- is_nil(loaded_first) or (is_integer(loaded_first) and loaded_first > 0),
         {:ok, id} <- cast_id(id) do
      with %{} = agent <- conversation_agent(id),
           :ok <-
             Signals.lock_target_in_tx(repo, %{
               agent_uid: agent.uid,
               session_id: Ankole.Sessions.Key.conversation(id)
             }),
           %Conversation{} = conversation <- visible_conversation(human_uid, id) do
        {:ok, detail(repo, conversation, agent, opts)}
      else
        _ -> {:error, :conversation_not_found}
      end
    else
      false -> {:error, :invalid_request}
      {:error, _} = error -> error
    end
  end

  def create(human_uid, attrs),
    do: human_uid |> start_native_conversation(attrs) |> Errors.reason() |> committed(human_uid)

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

      with :ok <- lock_participants_in_tx(repo, human_uid, agent_uid),
           :ok <- check_human_in_tx(repo, human_uid),
           {:ok, agent} <- active_agent_in_tx(repo, agent_uid),
           :ok <- Signals.lock_target_in_tx(repo, %{agent_uid: agent_uid, session_id: session_id}),
           {:ok, text, attachments} <- human_content(human_uid, id, message_id, attrs),
           :ok <- authorize_page(human_uid, page_id),
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

  def post(human_uid, id, attrs),
    do: human_uid |> post_native_message(id, attrs) |> Errors.reason() |> committed(human_uid)

  @doc "Changes only native follow-ups that have not been admitted to a turn."
  def update_queue(human_uid, id, attrs) when is_map(attrs),
    do: human_uid |> change_native_queue(id, attrs) |> Errors.reason() |> committed(human_uid)

  def update_queue(_human_uid, _id, _attrs), do: {:error, :invalid_request}

  @doc false
  def update_queue_in_tx(repo, human_uid, id, attrs) do
    with {:ok, id} <- cast_id(id),
         %Conversation{} = visible <- visible_conversation(human_uid, id),
         %{} = agent <- conversation_agent(id),
         session_id = Ankole.Sessions.Key.conversation(id),
         :ok <- lock_participants_in_tx(repo, human_uid, agent.uid),
         :ok <-
           Signals.lock_target_in_tx(repo, %{
             agent_uid: agent.uid,
             session_id: session_id
           }),
         :ok <- check_human_in_tx(repo, human_uid),
         :ok <- authorize_page(human_uid, visible.page_id),
         %Conversation{} = conversation <- visible_conversation(human_uid, id, lock: true),
         inputs = Locks.signals(pending_query(id)),
         true <- Enum.all?(inputs, &(&1.human_uid == human_uid)),
         {:ok, accepted_retry} <- accepted_retry(conversation, agent, attrs),
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
        with {:ok, _} <- put_queue_pause(conversation, false), do: {:ok, []}

      "reorder" ->
        reorder_inputs(inputs, Ankole.Attrs.get(attrs, :message_ids))

      action when action in ["regenerate", "edit_last"] ->
        retry_last_in_tx(repo, human_uid, conversation, agent, action, attrs)

      action when action in ["edit", "send_now", "remove"] ->
        with {:ok, id} <- cast_id(Ankole.Attrs.get(attrs, :message_id)),
             %Signal{} = input <-
               Enum.find(inputs, &(&1.message_id == id and &1.human_uid == human_uid)) do
          with {:ok, changed} <- change_input_in_tx(repo, input, action, attrs) do
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
      with {:ok, command_id} <- cast_id(Ankole.Attrs.get(attrs, :command_id)),
           {:ok, message_id} <- cast_id(Ankole.Attrs.get(attrs, :message_id)) do
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
    Ankole.Signals.list_signals!(
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

  defp retry_last_in_tx(repo, human_uid, conversation, agent, action, attrs) do
    with {:ok, command_id} <- cast_id(Ankole.Attrs.get(attrs, :command_id)),
         {:ok, message_id} <- cast_id(Ankole.Attrs.get(attrs, :message_id)) do
      key = %{agent_uid: agent.uid, session_id: Ankole.Sessions.Key.conversation(conversation.id)}
      now = DateTime.utc_now(:microsecond)

      with %Message{} = message <- conversation_message(conversation.id, message_id),
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
           :ok <- edit_last_in_tx(repo, message, action, attrs),
           {:ok, retry} <- Ankole.Sessions.Commands.retry_in_tx(repo, key, command, now),
           {:ok, retry} <-
             Ankole.Signals.update_metadata_signal(retry, %{
               data: Map.put(retry.data, "model_profile", ModelPreferences.logical(conversation))
             }),
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
    Message
    |> Ash.Query.filter(
      conversation_id == ^conversation_id and signal_id == ^signal_id and author_type == :agent
    )
    |> Ash.Query.lock(:for_update)
    |> Ankole.Ash.read!()
    |> Enum.reduce_while(:ok, fn message, :ok ->
      with :ok <- message_changed_in_tx(repo, message, nil, now),
           {:ok, _} <- Ankole.Ash.destroy(message, :remove) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp retry_input(
         _repo,
         human_uid,
         %Message{author_type: :human, author_uid: human_uid} = message,
         "edit_last"
       ) do
    [
      filter: [
        message_id: message.id,
        conversation_id: message.conversation_id,
        type: @addressed
      ],
      sort: [queue_sequence: :desc],
      limit: 1
    ]
    |> Locks.signals()
    |> List.first()
  end

  defp retry_input(
         repo,
         _human_uid,
         %Message{author_type: :agent, signal_id: signal_id} = message,
         "regenerate"
       )
       when not is_nil(signal_id) do
    case Signals.lock_signal_in_tx(repo, signal_id) do
      %Signal{} = input -> if retryable_reply?(message, input), do: input
      nil -> nil
    end
  end

  defp retry_input(_repo, _human_uid, _message, _action), do: nil

  defp edit_last_in_tx(_repo, _message, "regenerate", _attrs), do: :ok

  defp edit_last_in_tx(repo, message, "edit_last", attrs) do
    if Ankole.Attrs.get(attrs, :expected_text) == (message.text || "") do
      with {:ok, text} <- native_text(Ankole.Attrs.get(attrs, :text), message.attachments),
           {:ok, updated} <-
             Ankole.Ash.update(message, :edit, %{text: text, links: page_links(text)}),
           :ok <- message_changed_in_tx(repo, message, updated, DateTime.utc_now(:microsecond)),
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

  defp stop_queue_in_tx(repo, human_uid, conversation, agent, inputs, attrs) do
    with {:ok, command_id} <- cast_id(Ankole.Attrs.get(attrs, :command_id)) do
      case control_signal(agent, conversation, command_id) do
        %Signal{} = existing ->
          {:ok, [existing]}

        nil ->
          with {:ok, paused} <- pause_inputs(inputs),
               {:ok, _} <- put_queue_pause(conversation, true, command_id),
               {:ok, event} <-
                 Signals.accept_in_tx(repo, %{
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
      case Ankole.Signals.update_metadata_signal(input, %{
             data: Map.put(input.data, "delivery_mode", "queue")
           }) do
        {:ok, input} -> {:cont, {:ok, [input | paused]}}
        error -> {:halt, error}
      end
    end)
  end

  defp change_input_in_tx(repo, input, "edit", attrs) do
    with %Message{} = message <- message(input.message_id),
         {:ok, text} <- native_text(Ankole.Attrs.get(attrs, :text), message.attachments),
         {:ok, updated} <-
           Ankole.Ash.update(message, :edit, %{text: text, links: page_links(text)}),
         :ok <- message_changed_in_tx(repo, message, updated, DateTime.utc_now(:microsecond)),
         {:ok, input} <-
           Ankole.Signals.update_metadata_signal(input, %{
             data: put_input_text(input.data, text)
           }),
         do: {:ok, [input]}
  end

  defp change_input_in_tx(repo, input, "send_now", _attrs) do
    with :ok <-
           ModelPreferences.ensure_can_steer(
             repo,
             input.agent_uid,
             input.conversation_id,
             input.data["model_profile"] || "primary"
           ),
         {:ok, input} <-
           Ankole.Signals.update_metadata_signal(input, %{
             data: Map.put(input.data, "delivery_mode", "steer")
           }),
         do: {:ok, [input]}
  end

  defp change_input_in_tx(repo, input, "remove", _attrs) do
    # Retain the accepted identity so a late POST retry cannot recreate removed input.
    now = DateTime.utc_now(:microsecond)

    with %Message{} = message <- message(input.message_id),
         :ok <- message_changed_in_tx(repo, message, nil, now),
         {:ok, input} <-
           Ankole.Signals.update_metadata_signal(input, %{
             data: Map.put(input.data, "removed", true)
           }),
         {:ok, input} <- Ankole.Sessions.Queue.mark_event_completed_in_tx(repo, input, now),
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
        case Ankole.Signals.update_metadata_signal(Map.fetch!(by_id, id), %{
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
    case Ankole.Signals.list_signals!(
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

  @doc "Deletes an idle native conversation owned by the current Human. Pages remain independent."
  def delete(human_uid, id), do: human_uid |> remove_native_conversation(id) |> Errors.reason()

  @doc false
  def delete_in_tx(repo, human_uid, id) do
    with {:ok, id} <- cast_id(id),
         {:ok, %{agent: agent}} <- detail_in_tx(repo, human_uid, id, []),
         :ok <-
           Signals.lock_target_in_tx(repo, %{
             agent_uid: agent.uid,
             session_id: Ankole.Sessions.Key.conversation(id)
           }),
         %Conversation{kind: :native, created_by: ^human_uid} = conversation <-
           lock_conversation(id),
         false <- busy?(id),
         {:ok, _} <-
           AIGateway.end_active_conversation_in_tx(
             repo,
             agent.uid,
             Ankole.Sessions.Key.conversation(id),
             DateTime.utc_now(:microsecond)
           ),
         {:ok, _} <- Ankole.Ash.destroy(conversation, :remove) do
      {:ok, id}
    else
      true -> {:error, :conversation_busy}
      {:error, _} = error -> error
      _ -> {:error, :conversation_not_found}
    end
  end

  defp busy?(id) do
    Ankole.Signals.list_signals!(
      query: [
        filter: [
          or: [[conversation_id: id], [session_id: Ankole.Sessions.Key.conversation(id)]],
          status: [in: [:queued, :running]]
        ],
        limit: 1,
        select: [:id]
      ]
    ) != []
  end

  @doc "Appends human input and returns publication facts to its transaction owner."
  def post_in_tx(repo, human_uid, id, attrs) when is_map(attrs) do
    with :ok <- Repo.require_transaction(repo),
         {:ok, id} <- cast_id(id),
         {:ok, message_id} <- cast_id(Ankole.Attrs.get(attrs, :message_id)),
         {:ok, mode} <- delivery_mode(Ankole.Attrs.get(attrs, :delivery_mode)),
         %Conversation{} <- visible_conversation(human_uid, id),
         %{} = agent <- conversation_agent(id) do
      with :ok <- lock_participants_in_tx(repo, human_uid, agent.uid),
           :ok <- check_human_in_tx(repo, human_uid),
           :ok <-
             Signals.lock_target_in_tx(repo, %{
               agent_uid: agent.uid,
               session_id: Ankole.Sessions.Key.conversation(id)
             }),
           {:ok, text, attachments} <- human_content(human_uid, id, message_id, attrs),
           {:ok, agent} <- active_agent_in_tx(repo, agent.uid),
           %Conversation{} = conversation <- visible_conversation(human_uid, id, lock: true),
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
         %Conversation{kind: :native} = conversation <- lock_conversation(id),
         %{uid: uid} <- conversation_agent(id),
         true <- uid == event.agent_uid do
      case Message
           |> Ash.Query.filter(conversation_id == ^id and signal_id == ^event.id)
           |> Ankole.Ash.read_one!() do
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

            with {:ok, message} <- Ankole.Ash.create(Message, :record, attrs),
                 {:ok, _} <- touch(conversation, message.created_at) do
              {:ok, message}
            end
          end
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :conversation_not_found}
    end
  end

  @doc """
  Returns the native host IDs for model-history lifecycle queries.

  This Ecto query stays for the Sessions callers that compose it into their
  own Ecto queries. New callers filter `list_conversations/1` by `kind`.
  """
  def native_ids_query do
    import Ecto.Query, only: [from: 2]
    from(c in Conversation, where: c.kind == :native, select: c.id)
  end

  @doc """
  The retained Message identities withdrawn from public conversation facts.

  This Ecto query stays for the Brain callers that compose it into their own
  Ecto queries. New callers filter Messages by the `withdrawn` calculation.
  """
  def removed_message_ids_query(conversation_id \\ nil) do
    import Ecto.Query, only: [from: 2]

    query =
      from(input in Signal,
        where: input.data["removed"] == true and not is_nil(input.message_id),
        select: input.message_id
      )

    if is_nil(conversation_id),
      do: query,
      else: from(input in query, where: input.conversation_id == ^conversation_id)
  end

  @doc "Reads a bounded snapshot of statements not yet included by the caller."
  def context_snapshot(id, key, read_seq, excluded_ids, opts \\ []),
    do: id |> read_context_snapshot(key, read_seq, excluded_ids, opts) |> Errors.reason()

  @doc false
  def context_snapshot_in_tx(
        _repo,
        id,
        %{agent_uid: agent_uid, session_id: session_id},
        read_seq,
        excluded_ids,
        opts
      ) do
    limit = min(max(Keyword.get(opts, :limit, 50), 1), 500)

    with {:ok, id} <- cast_id(id),
         %Conversation{} = conversation <-
           Conversation
           |> Ash.Query.filter(id == ^id)
           |> Ash.Query.lock("FOR SHARE")
           |> Ankole.Ash.read_one!() do
      max_seq = conversation.sequence_high_water

      messages =
        Message
        |> Ash.Query.filter(
          conversation_id == ^id and seq > ^read_seq and seq <= ^max_seq and
            (is_nil(session_id) or session_id != ^session_id or is_nil(author_uid) or
               author_uid != ^agent_uid) and id not in ^excluded_ids and not withdrawn and
            not exists(
              Signal,
              message_id == parent(id) and conversation_id == ^id and producer == :kernel and
                type == ^@addressed and status in [:queued, :running] and
                is_nil(last_attempt_at)
            )
        )
        |> Ash.Query.sort(seq: :desc)
        |> Ash.Query.limit(limit)
        |> Ankole.Ash.read!()
        |> Enum.reverse()

      {:ok, %{messages: messages, max_seq: max_seq}}
    else
      {:error, _} = error -> error
      _ -> {:error, :conversation_not_found}
    end
  end

  @doc false
  def ids_for_agent_in_tx(_repo, uid) do
    uid
    |> native_conversations_of_agent()
    |> Ash.Query.select([:id])
    |> Ankole.Ash.read!()
    |> Enum.map(& &1.id)
  end

  @doc false
  def delete_for_agent_in_tx(_repo, uid) do
    case uid |> native_conversations_of_agent() |> Ankole.Ash.destroy_where(:remove) do
      {:ok, _conversations} -> :ok
      {:error, _} = error -> error
    end
  end

  defp native_conversations_of_agent(uid) do
    Ash.Query.filter(
      Conversation,
      kind == :native and
        exists(
          Participant,
          conversation_id == parent(id) and principal_uid == ^uid and role == :agent
        )
    )
  end

  defp publications(id, true), do: [{id, :message}]
  defp publications(_id, false), do: []

  @doc false
  # The generic actions of native conversations publish their committed changes.
  def publish_native_change(%{publications: publications} = result) do
    Ankole.Conversations.Events.publish_committed(publications)

    if publications != [] do
      key = result.session_key
      Ankole.Sessions.Events.publish_status(key.agent_uid, key.session_id)
    end

    :ok
  end

  defp committed({:ok, %{id: id} = result}, human_uid),
    do: get(human_uid, id, removed_message_ids: Map.get(result, :removed_message_ids, []))

  defp committed({:error, _} = error, _human_uid), do: error

  defp ensure_conversation_in_tx(repo, human_uid, agent, id, text, page_id) do
    attrs = %{
      id: id,
      title: text |> String.trim() |> String.split("\n", parts: 2) |> hd() |> String.slice(0, 80),
      created_by: human_uid,
      page_id: page_id,
      last_activity_at: DateTime.utc_now(:microsecond)
    }

    with :ok <- available_native_id(repo, agent.uid, id),
         {:ok, _} <-
           Ankole.Ash.create(Conversation, :ensure_native, attrs, touch_update_defaults?: false),
         %Conversation{created_by: ^human_uid, page_id: ^page_id} = conversation <-
           lock_conversation(id),
         :ok <- check_existing_agent(id, agent.uid),
         {:ok, _} <- insert_participant(id, human_uid, :owner),
         {:ok, _} <- insert_participant(id, agent.uid, :agent),
         %{uid: uid} <- conversation_agent(id),
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

    exists? =
      Conversation
      |> Ash.Query.filter(id == ^id)
      |> Ash.Query.select([:id])
      |> Ankole.Ash.read_one!()
      |> is_struct()

    used? =
      AIGateway.conversation_exists_by_key?(repo, agent_uid, session_id) or
        Ankole.Signals.list_signals!(
          query: [
            filter: [agent_uid: agent_uid, session_id: session_id],
            limit: 1,
            select: [:id]
          ]
        ) != []

    if exists? or not used?, do: :ok, else: {:error, :conversation_conflict}
  end

  defp insert_participant(id, uid, role) do
    Ankole.Ash.create(Participant, :join, %{conversation_id: id, principal_uid: uid, role: role})
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

  defp check_existing_agent(id, uid) do
    case conversation_agent(id) do
      nil -> :ok
      %{uid: ^uid} -> :ok
      _ -> {:error, :conversation_conflict}
    end
  end

  defp human_content(uid, conversation_id, message_id, attrs) do
    existing =
      Message
      |> Ash.Query.filter(
        id == ^message_id and conversation_id == ^conversation_id and author_uid == ^uid
      )
      |> Ankole.Ash.read_one!()

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
    existing = message(id)

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
                 Ankole.Ash.create(Message, :record_once, attrs),
               %Message{
                 conversation_id: conversation_id,
                 author_uid: ^human_uid,
                 text: ^text,
                 attachments: ^attachments,
                 author_type: :human,
                 kind: :message
               } = message <- message(id),
               true <- conversation_id == conversation.id,
               {:ok, _} <- touch(conversation, message.created_at) do
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
      type: @addressed,
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

  # The native inputs of a conversation that a turn has not admitted yet.
  defp pending_query(conversation_id) do
    [
      filter: [
        conversation_id: conversation_id,
        type: @addressed,
        status: [in: [:queued, :running]],
        last_attempt_at: [is_nil: true]
      ],
      sort: [queue_sequence: :asc]
    ]
  end

  @doc "Allocates one committed statement sequence in the caller's transaction."
  def next_sequence_in_tx(_repo, %Conversation{id: id}) do
    case lock_conversation(id) do
      %Conversation{} = conversation ->
        with {:ok, updated} <- Ankole.Ash.update(conversation, :advance_sequence, %{}),
             do: {:ok, updated.sequence_high_water}

      nil ->
        {:error, :conversation_not_found}
    end
  end

  defp touch(conversation, now) do
    Ankole.Ash.update(conversation, :touch, %{last_activity_at: now})
  end

  defp lock_conversation(id) do
    Conversation
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.lock(:for_update)
    |> Ankole.Ash.read_one!()
  end

  defp message(id), do: Message |> Ash.Query.filter(id == ^id) |> Ankole.Ash.read_one!()

  defp conversation_message(conversation_id, id) do
    Message
    |> Ash.Query.filter(id == ^id and conversation_id == ^conversation_id)
    |> Ankole.Ash.read_one!()
  end

  defp lock_participants_in_tx(repo, human_uid, agent_uid) do
    {:ok, _principals} = Ankole.Principals.lock_principals_in_tx(repo, [human_uid, agent_uid])
    :ok
  end

  defp check_human_in_tx(repo, human_uid) do
    if active_human?(human_uid),
      do: WorkAccess.check_in_tx(repo, WorkAccess.from_sender(repo, human_uid)),
      else: {:error, :invalid_request}
  end

  defp active_agent_in_tx(repo, agent_uid) do
    case Ankole.Principals.lock_principals_in_tx(repo, [agent_uid]) do
      {:ok, [%{type: :agent, status: :active} = agent]} -> {:ok, agent}
      _ -> {:error, :agent_unavailable}
    end
  end

  defp active_human?(uid) when is_binary(uid) and uid != "",
    do: match?(%{type: :human, status: :active}, Ankole.Principals.get_principal_record!(uid))

  defp active_human?(_uid), do: false

  # A native conversation that the Human takes part in, while the Human is active.
  defp visible_conversation(human_uid, id, opts \\ []) do
    if active_human?(human_uid) do
      query =
        Ash.Query.filter(
          Conversation,
          id == ^id and kind == :native and
            exists(Participant, conversation_id == parent(id) and principal_uid == ^human_uid)
        )

      query = if opts[:lock], do: Ash.Query.lock(query, :for_update), else: query
      Ankole.Ash.read_one!(query)
    end
  end

  defp conversation_agent(id), do: [id] |> conversation_agents() |> Map.get(id)

  # The agent Principal of each conversation.
  defp conversation_agents([]), do: %{}

  defp conversation_agents(ids) do
    participants =
      Participant
      |> Ash.Query.filter(conversation_id in ^ids and role == :agent)
      |> Ankole.Ash.read!()

    agents =
      Ankole.Principals.list_principals!(
        query: [filter: [uid: [in: Enum.map(participants, & &1.principal_uid)]]]
      )
      |> Map.new(&{&1.uid, &1})

    for participant <- participants,
        agent = Map.get(agents, participant.principal_uid),
        into: %{},
        do: {participant.conversation_id, agent}
  end

  defp detail(repo, conversation, agent, opts) do
    query =
      Message
      |> Ash.Query.filter(
        conversation_id == ^conversation.id and seq <= ^conversation.sequence_high_water and
          not withdrawn
      )
      |> Ash.Query.sort(seq: :desc)
      |> Ash.Query.limit(501)

    query =
      case Keyword.get(opts, :before_seq) do
        nil -> query
        sequence -> Ash.Query.filter(query, seq < ^sequence)
      end

    rows = Ankole.Ash.read!(query)
    messages = rows |> Enum.take(500) |> Enum.reverse()
    older_before = if length(rows) > 500, do: hd(messages).seq, else: nil
    loaded_first = min(opts[:loaded_first_seq] || older_before || 1, older_before || 1)

    removed_ids =
      Message
      |> Ash.Query.filter(
        conversation_id == ^conversation.id and seq >= ^loaded_first and
          seq <= ^conversation.sequence_high_water and withdrawn
      )
      |> Ash.Query.select([:id])
      |> Ankole.Ash.read!()
      |> Enum.map(& &1.id)
      |> Enum.concat(opts[:removed_message_ids] || [])
      |> Enum.uniq()

    model =
      AIGateway.list_active_conversations(repo,
        subject_uid: agent.uid,
        conversation_key: Ankole.Sessions.Key.conversation(conversation.id),
        limit: 1
      )
      |> List.first()

    pending_inputs = Ankole.Signals.list_signals!(query: pending_query(conversation.id))

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
      retryable_message_id: retryable_message_id(repo, conversation, agent, messages, opts),
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
  defp retryable_message_id(repo, conversation, agent, messages, opts) do
    message =
      if opts[:before_seq] do
        Message
        |> Ash.Query.filter(conversation_id == ^conversation.id and not withdrawn)
        |> Ash.Query.sort(seq: :desc)
        |> Ash.Query.limit(1)
        |> Ankole.Ash.read_one!()
      else
        List.last(messages)
      end

    case message do
      %Message{author_type: :agent, signal_id: signal_id} when not is_nil(signal_id) ->
        key = %{
          agent_uid: agent.uid,
          session_id: Ankole.Sessions.Key.conversation(conversation.id)
        }

        with {:ok, %Signal{} = input} <-
               Ankole.Sessions.Commands.retry_source_in_tx(repo, key, nil, signal_id),
             true <- retryable_reply?(message, input) do
          message.id
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp retryable_reply?(%Message{kind: :message}, %Signal{}), do: true

  defp retryable_reply?(%Message{kind: :notice}, %Signal{
         status: :dead_letter,
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
