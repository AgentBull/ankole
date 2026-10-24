defmodule Ankole.Sessions.ModelHistory do
  @moduledoc """
  Client of AIGateway for Session inputs, recovery, and model history.

  `signal_id` is opaque client metadata to AIGateway. This module maps
  Signal inputs to the stored Response chain and signal projections. Session
  Drivers own step progress; RequestContext uses the same input identity for the
  hosted Brain tool.
  """

  alias Ankole.AIGateway
  alias Ankole.AIGateway.Schemas.Conversation
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.Principals
  alias Ankole.Signals.Signal
  alias Ankole.Sessions.RunRef
  alias Ankole.Conversations.Conversation, as: PublicConversation

  @max_chain_depth 500
  @scheduled_event_types ~w(check_back_later.wakeup cron.fire)

  @type turn_chain :: %{
          conversation: Conversation.t(),
          final_response: Message.t(),
          response_chain: [Message.t()]
        }

  @type session_key :: %{required(:agent_uid) => String.t(), required(:session_id) => String.t()}

  @doc false
  @spec ensure_and_lock_conversation_in_tx(
          String.t(),
          String.t(),
          Signal.t()
        ) ::
          {:ok, Conversation.t()} | {:error, term()}
  def ensure_and_lock_conversation_in_tx(
        subject_uid,
        conversation_key,
        %Signal{} = signal
      ) do
    with {:ok, origin} <- conversation_origin(signal) do
      ensure_and_lock_active_conversation(
        subject_uid,
        conversation_key,
        initial_origin_metadata(origin)
      )
    end
  end

  @doc false
  @spec successor_origin_metadata(Conversation.t()) :: map()
  def successor_origin_metadata(%Conversation{metadata: metadata}) do
    case Map.get(metadata || %{}, "origin") do
      %{} = origin -> %{"origin" => origin}
      _other -> %{}
    end
  end

  @doc false
  @spec active_conversation(String.t(), String.t()) :: Conversation.t() | nil
  def active_conversation(subject_uid, conversation_key) do
    AIGateway.list_active_conversations(
      subject_uid: subject_uid,
      conversation_key: conversation_key,
      limit: 1
    )
    |> List.first()
  end

  @doc "Ends model history and records the Session's Brain learning trigger atomically."
  def end_active_conversation_in_tx(subject_uid, session_id, now) do
    with {:ok, conversation} <-
           AIGateway.end_active_conversation_in_tx(subject_uid, session_id, now),
         :ok <- Ankole.Brain.ConversationTriggers.conversation_ended_in_tx(session_id) do
      {:ok, conversation}
    end
  end

  # The `conversation_id: nil` clause covers a non-channel-triggering event
  # (for example, an internal command). Its conversation has no channel or DM
  # to record, so origin stays undeclared rather than forcing a lookup that has
  # nothing to find.
  defp conversation_origin(%Signal{conversation_id: nil}), do: {:ok, :undeclared}

  defp conversation_origin(%Signal{} = signal) do
    case Ankole.Conversations.get_conversation!(signal.conversation_id) do
      %PublicConversation{kind: :external, external_kind: :im_dm} = channel ->
        with {:ok, peer_uid} <- dm_peer_uid(signal, channel) do
          {:ok,
           %{
             "peer_uid" => peer_uid,
             "conversation_id" => channel.id,
             "channel_kind" => Atom.to_string(channel.external_kind)
           }}
        end

      %PublicConversation{} = channel ->
        {:ok,
         %{
           "conversation_id" => channel.id,
           "channel_kind" => Atom.to_string(channel.external_kind || channel.kind)
         }}

      nil ->
        if signal.type in @scheduled_event_types &&
             Ankole.Sessions.Scheduled.produced_signal?(signal) do
          {:ok, :undeclared}
        else
          {:error, {:conversation_origin_channel_not_found, signal.conversation_id}}
        end
    end
  end

  defp dm_peer_uid(%Signal{} = signal, %PublicConversation{} = channel) do
    peer_uid =
      Map.get(channel.metadata || %{}, "dm_peer_principal_uid") ||
        if(signal.authorization_kind == "human", do: signal.human_uid) ||
        case Ankole.Conversations.message_for_signal(signal) do
          %{author_type: :human, author_uid: uid} -> uid
          _ -> nil
        end

    case Principals.normalize_uid(peer_uid) do
      {:ok, peer_uid} -> {:ok, peer_uid}
      {:error, _reason} -> {:error, {:conversation_origin_dm_peer_missing, channel.id}}
    end
  end

  defp initial_origin_metadata(:undeclared), do: %{}
  defp initial_origin_metadata(%{} = origin), do: %{"origin" => origin}

  defp ensure_and_lock_active_conversation(
         subject_uid,
         conversation_key,
         initial_metadata
       ) do
    with {:ok, conversation} <-
           AIGateway.ensure_conversation_in_tx(
             subject_uid,
             conversation_key,
             initial_metadata
           ),
         %Conversation{} = conversation <- AIGateway.lock_conversation(conversation.id) do
      if is_nil(conversation.ended_at) do
        {:ok, conversation}
      else
        ensure_and_lock_active_conversation(
          subject_uid,
          conversation_key,
          initial_metadata
        )
      end
    else
      nil -> {:error, :conversation_not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec publish_failed_response(Message.t() | nil) :: :ok | {:error, term()}
  def publish_failed_response(nil), do: :ok

  def publish_failed_response(%Message{} = response) do
    error = Map.get(response.metadata || %{}, "error", %{"code" => "response_failed"})
    AIGateway.publish_terminal_event(response, :response_failed, %{error: error})
  end

  @doc "Returns Message IDs read by model calls owned by this Signal."
  def read_message_ids_in_tx(%Signal{} = signal) do
    case active_conversation(signal.agent_uid, signal.session_id) do
      nil ->
        []

      conversation ->
        {:ok, rows} =
          AIGateway.list_conversation_responses_in_tx(signal.agent_uid, conversation.id)

        rows
        |> Enum.flat_map(fn row ->
          metadata = AIGateway.response_metadata(row)

          case metadata["conversation_read"] do
            %{"id" => id, "message_ids" => ids}
            when id == signal.conversation_id and is_list(ids) ->
              if metadata["signal_id"] == signal.id, do: ids, else: []

            _ ->
              []
          end
        end)
        |> Enum.uniq()
    end
  end

  @doc false
  @spec delete_visible_turn_suffix_in_tx(
          String.t(),
          String.t(),
          String.t(),
          DateTime.t()
        ) :: {:ok, map()} | {:error, term()}
  def delete_visible_turn_suffix_in_tx(
        subject_uid,
        conversation_key,
        signal_id,
        %DateTime{} = now
      ) do
    case AIGateway.active_conversation_for_update(subject_uid, conversation_key) do
      %Conversation{} = conversation ->
        delete_visible_turn_suffix(conversation, signal_id, now)

      nil ->
        {:ok, suffix_delete_noop(:conversation_not_found)}
    end
  end

  @doc false
  @spec retract_visible_turn_suffix_in_tx(
          String.t(),
          String.t(),
          String.t(),
          DateTime.t(),
          keyword()
        ) :: {:ok, map()} | {:error, term()}
  def retract_visible_turn_suffix_in_tx(
        subject_uid,
        conversation_key,
        signal_id,
        %DateTime{} = now,
        opts \\ []
      ) do
    case AIGateway.active_conversation_for_update(subject_uid, conversation_key) do
      %Conversation{} = conversation ->
        retract_visible_turn_suffix(conversation, signal_id, now, opts)

      nil ->
        {:ok, suffix_retraction_noop(:conversation_not_found)}
    end
  end

  @doc """
  Loads the Response chain that ends at `final_response_id` and validates that
  it belongs to the turn: the same Agent and conversation, one Signal, and
  a terminal successful final Response.

  A silent completion that adopted a Response validates these facts without a
  reply projection.
  """
  @spec load_turn_chain(RunRef.t(), String.t()) :: {:ok, turn_chain()} | {:error, term()}
  def load_turn_chain(
        %{agent_uid: _, session_id: _, signal_id: _} = turn_ref,
        final_response_id
      )
      when is_binary(final_response_id) do
    with :ok <- validate_response_id(final_response_id),
         {:ok, chain} <-
           AIGateway.list_response_chain(
             turn_ref.agent_uid,
             final_response_id,
             @max_chain_depth
           ),
         {:ok, final_response} <- final_response(chain, final_response_id),
         {:ok, conversation} <-
           AIGateway.get_conversation(
             turn_ref.agent_uid,
             final_response.conversation_id
           ),
         :ok <- validate_conversation(conversation, turn_ref),
         {:ok, turn_chain} <- turn_response_chain(chain, turn_ref) do
      {:ok,
       %{
         conversation: conversation,
         final_response: final_response,
         response_chain: turn_chain
       }}
    end
  end

  def load_turn_chain(%{signal_id: _}, _final_response_id),
    do: {:error, :invalid_final_response_id}

  defp request_ref_signal_ids(request_refs) when is_list(request_refs) do
    Enum.flat_map(request_refs, fn
      %{"signal_id" => signal_id} when is_binary(signal_id) -> [signal_id]
      %{signal_id: signal_id} when is_binary(signal_id) -> [signal_id]
      _ref -> []
    end)
  end

  defp request_ref_signal_ids(_request_refs), do: []

  defp delete_visible_turn_suffix(%Conversation{} = conversation, signal_id, now) do
    with {:ok, responses} <-
           AIGateway.list_conversation_responses_in_tx(
             conversation.subject_uid,
             conversation.id,
             statuses: [:complete, :generating],
             lock: true
           ) do
      complete_responses = Enum.filter(responses, &(&1.status == :complete))

      case select_visible_signal_suffix(complete_responses, signal_id) do
        {:noop, reason} ->
          {:ok, suffix_delete_noop(reason)}

        {:ok, suffix} ->
          generating_responses =
            Enum.filter(responses, fn response ->
              response.status == :generating and
                ordinary_response?(response) and
                response_signal_id(response) == signal_id
            end)

          error = %{
            "code" => "source_entry_removed",
            "failed_at" => DateTime.to_iso8601(now),
            "reason" => "source_entry_removed_before_terminal_commit",
            "stage" => "entry_lifecycle",
            "retryable" => false
          }

          with {:ok, failed_responses} <-
                 fail_response_rows_in_tx(
                   conversation.subject_uid,
                   generating_responses,
                   error,
                   now
                 ),
               {:ok, deletion} <-
                 AIGateway.hard_delete_visible_suffix_in_tx(
                   conversation.subject_uid,
                   conversation.id,
                   Enum.map(suffix, &response_id/1)
                 ) do
            {:ok,
             Map.merge(deletion, %{
               failed_generating_message_ids: Enum.map(failed_responses, & &1.id),
               failed_generating_count: length(failed_responses)
             })}
          end
      end
    end
  end

  defp retract_visible_turn_suffix(
         %Conversation{} = conversation,
         signal_id,
         now,
         opts
       ) do
    with {:ok, responses} <-
           AIGateway.list_conversation_responses_in_tx(
             conversation.subject_uid,
             conversation.id,
             statuses: [:complete],
             lock: true
           ) do
      case select_visible_signal_suffix(responses, signal_id) do
        {:noop, reason} ->
          {:ok, suffix_retraction_noop(reason)}

        {:ok, suffix} ->
          if Keyword.get(opts, :preserve_tool_history, false) and
               not Enum.all?(suffix, &response_replay_safe?/1) do
            {:ok, %{status: :preserved, preserved_message_ids: Enum.map(suffix, & &1.id)}}
          else
            AIGateway.retract_visible_suffix_in_tx(
              conversation.subject_uid,
              conversation.id,
              Enum.map(suffix, &response_id/1),
              reason: Keyword.get(opts, :reason, "command.retry"),
              retracted_at: now
            )
          end
      end
    end
  end

  defp select_visible_signal_suffix(complete_responses, signal_id) do
    suffix = visible_signal_suffix(complete_responses, signal_id)

    case suffix do
      [] ->
        visible_chain = current_visible_chain(complete_responses)

        reason =
          if Enum.any?(visible_chain, &(response_signal_id(&1) == signal_id)) do
            :not_visible_tail
          else
            :signal_not_visible
          end

        {:noop, reason}

      [_response | _rest] ->
        {:ok, suffix}
    end
  end

  defp visible_signal_suffix(complete_responses, signal_id) do
    by_id = Map.new(complete_responses, &{&1.id, &1})
    leaf = visible_leaf(complete_responses)

    take_signal_suffix(leaf, by_id, signal_id, MapSet.new())
  end

  defp current_visible_chain(complete_responses) do
    by_id = Map.new(complete_responses, &{&1.id, &1})
    walk_visible_chain(visible_leaf(complete_responses), by_id, MapSet.new())
  end

  defp visible_leaf(complete_responses) do
    parent_ids =
      complete_responses
      |> Enum.map(& &1.previous_message_id)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    Enum.find(complete_responses, &(not MapSet.member?(parent_ids, &1.id)))
  end

  defp walk_visible_chain(nil, _by_id, _seen), do: []

  defp walk_visible_chain(%Message{} = response, by_id, seen) do
    cond do
      MapSet.member?(seen, response.id) ->
        []

      response.type == :checkpoint ->
        [response]

      true ->
        parent = Map.get(by_id, response.previous_message_id)
        [response | walk_visible_chain(parent, by_id, MapSet.put(seen, response.id))]
    end
  end

  defp take_signal_suffix(nil, _by_id, _signal_id, _seen), do: []

  defp take_signal_suffix(%Message{} = response, by_id, signal_id, seen) do
    cond do
      MapSet.member?(seen, response.id) ->
        []

      not ordinary_response?(response) ->
        []

      response_signal_id(response) != signal_id ->
        []

      true ->
        parent = Map.get(by_id, response.previous_message_id)

        [
          response
          | take_signal_suffix(parent, by_id, signal_id, MapSet.put(seen, response.id))
        ]
    end
  end

  defp fail_response_rows_in_tx(subject_uid, responses, error, now) do
    Enum.reduce_while(responses, {:ok, []}, fn response, {:ok, failed} ->
      case AIGateway.fail_generating_response_in_tx(
             subject_uid,
             response_id(response),
             error,
             now
           ) do
        {:ok, %Message{} = response} -> {:cont, {:ok, [response | failed]}}
        {:ok, :already_terminal} -> {:cont, {:ok, failed}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, failed} -> {:ok, Enum.reverse(failed)}
      {:error, _reason} = error -> error
    end
  end

  defp suffix_delete_noop(reason) do
    %{
      status: :noop,
      reason: reason,
      deleted_message_ids: [],
      deleted_count: 0
    }
  end

  defp suffix_retraction_noop(reason) do
    %{
      status: :noop,
      reason: reason,
      retracted_message_ids: [],
      retracted_count: 0
    }
  end

  defp response_signal_ids(%Message{} = response) do
    metadata = AIGateway.response_metadata(response)
    [metadata["signal_id"] | request_ref_signal_ids(metadata["request_refs"])]
  end

  defp response_signal_id(%Message{} = response),
    do: AIGateway.response_metadata(response)["signal_id"]

  defp ordinary_response?(%Message{type: :message}), do: true
  defp ordinary_response?(_response), do: false

  defp validate_response_id("resp_" <> uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, _uuid} -> :ok
      :error -> {:error, :invalid_final_response_id}
    end
  end

  defp validate_response_id(_response_id), do: {:error, :invalid_final_response_id}

  defp final_response([%Message{} = final | _rest], final_response_id) do
    cond do
      response_id(final) != final_response_id ->
        {:error, :final_response_mismatch}

      final.type != :message ->
        {:error, :final_response_not_message}

      final.status != :complete ->
        {:error, :final_response_not_terminal_success}

      true ->
        {:ok, final}
    end
  end

  defp final_response(_chain, _final_response_id), do: {:error, :final_response_not_found}

  defp validate_conversation(%Conversation{} = conversation, turn_ref) do
    cond do
      conversation.subject_uid != turn_ref.agent_uid ->
        {:error, :response_subject_mismatch}

      conversation.conversation_key != turn_ref.session_id ->
        {:error, :response_conversation_mismatch}

      true ->
        :ok
    end
  end

  defp turn_response_chain(chain, turn_ref) when is_list(chain) do
    turn_chain =
      Enum.take_while(chain, fn
        %Message{} = message ->
          AIGateway.response_metadata(message)["signal_id"] ==
            turn_ref.signal_id

        _message ->
          false
      end)

    cond do
      turn_chain == [] ->
        {:error, :response_signal_mismatch}

      Enum.any?(turn_chain, &invalid_chain_row?(&1, turn_ref)) ->
        {:error, :response_chain_scope_mismatch}

      chain_depth_exceeded?(turn_chain) ->
        {:error, :response_chain_too_deep}

      true ->
        {:ok, turn_chain}
    end
  end

  defp invalid_chain_row?(%Message{} = message, turn_ref) do
    message.subject_uid != turn_ref.agent_uid or message.status != :complete
  end

  defp chain_depth_exceeded?(turn_chain) do
    length(turn_chain) == @max_chain_depth and
      match?(
        %Message{previous_message_id: previous} when not is_nil(previous),
        List.last(turn_chain)
      )
  end

  defp response_id(%Message{id: id}), do: "resp_#{id}"

  defp generating_responses_for_signal_in_tx(session_key, signal_id) do
    case AIGateway.active_conversation_for_update(
           session_key.agent_uid,
           session_key.session_id
         ) do
      %Conversation{} = conversation ->
        case AIGateway.list_conversation_responses_in_tx(
               session_key.agent_uid,
               conversation.id,
               statuses: [:generating],
               lock: true
             ) do
          {:ok, responses} ->
            Enum.filter(responses, fn response ->
              ordinary_response?(response) and
                response_signal_id(response) == signal_id
            end)

          {:error, _reason} ->
            []
        end

      nil ->
        []
    end
  end

  @doc false
  def retract_generating_turn_in_tx(session_key, signal_id, now, reason)
      when is_binary(reason) do
    generating_responses_for_signal_in_tx(session_key, signal_id)
    |> Enum.reduce_while({:ok, []}, fn response, {:ok, retracted} ->
      case AIGateway.retract_generating_response_in_tx(
             session_key.agent_uid,
             response_id(response),
             reason,
             now
           ) do
        {:ok, %Message{} = response} -> {:cont, {:ok, [response | retracted]}}
        {:ok, :already_terminal} -> {:cont, {:ok, retracted}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, retracted} -> {:ok, List.last(retracted)}
      error -> error
    end
  end

  @doc false
  def exact_turn_retryable_in_tx(session_key, signal_id) do
    case AIGateway.active_conversation_for_update(
           session_key.agent_uid,
           session_key.session_id
         ) do
      %Conversation{} = conversation ->
        case AIGateway.list_conversation_responses_in_tx(
               session_key.agent_uid,
               conversation.id,
               statuses: [:generating, :complete, :error],
               lock: true
             ) do
          {:ok, responses} ->
            responses
            |> Enum.filter(&(signal_id in response_signal_ids(&1)))
            |> Enum.all?(fn response ->
              exact_response_owner?(response, signal_id) and
                (response.status != :error or response_replay_safe?(response))
            end)

          {:error, _} ->
            false
        end

      nil ->
        true
    end
  end

  defp response_replay_safe?(%Message{content: content}) when is_list(content) do
    Enum.all?(content, fn
      %{"type" => type} when type in ["message", "reasoning"] -> true
      %{type: type} when type in ["message", "reasoning"] -> true
      %{"role" => "user", "content" => _} -> true
      %{role: "user", content: _} -> true
      _ -> false
    end)
  end

  defp response_replay_safe?(%Message{}), do: false

  defp exact_response_owner?(%Message{} = response, signal_id) do
    metadata = AIGateway.response_metadata(response)

    response_signal_id(response) == signal_id and
      request_ref_signal_ids(metadata["request_refs"]) == []
  end
end
