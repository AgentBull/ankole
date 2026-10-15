defmodule Ankole.Sessions.ModelHistory do
  @moduledoc """
  Client of AIGateway for Session inputs, recovery, and model history.

  `signal_id` is opaque client metadata to AIGateway. This module maps
  Signal inputs to the stored Response chain and signal projections. Session
  Drivers own step progress; RequestContext uses the same input identity for the
  hosted Brain tool.
  """

  import Ecto.Query, warn: false

  alias Ankole.AIGateway
  alias Ankole.AIGateway.Artifacts
  alias Ankole.AIGateway.Schemas.Conversation
  alias Ankole.AIGateway.Schemas.Artifact
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.BackgroundAgentJobs
  alias Ankole.Principals
  alias Ankole.Repo
  alias Ankole.Signals.Signal
  alias Ankole.Sessions.Queue
  alias Ankole.Sessions.RunRef
  alias Ankole.Sessions.SessionWorkspace
  alias Ankole.Conversations.Delivery.Text
  alias Ankole.Conversations.Conversation, as: PublicConversation
  alias Ankole.Conversations.Delivery.ClarifyPrompt
  alias Ankole.Conversations.Delivery.Attachment

  alias Ankole.Files

  @doc """
  Reads a caller's visible run suffix.

  Tool-result journals and compaction checkpoints do not end the suffix.
  The caller metadata remains opaque; only its run identity is compared.
  """
  def conversation_tail(%Conversation{} = conversation, signal_id) do
    {:ok, history} =
      AIGateway.visible_response_chain(conversation.subject_uid, conversation.id,
        stop_at_checkpoint: false
      )

    leaf =
      case List.last(history) do
        nil -> nil
        message -> message.id
      end

    rows =
      history
      |> Enum.reverse()
      |> Enum.reduce_while([], fn row, rows ->
        cond do
          row.type == "checkpoint" -> {:cont, rows}
          AIGateway.response_metadata(row)["signal_id"] == signal_id -> {:cont, [row | rows]}
          row.metadata["tool_result_journal"] == true -> {:cont, rows}
          true -> {:halt, rows}
        end
      end)

    responses = Enum.reject(rows, &(&1.metadata["tool_result_journal"] == true))
    latest = List.last(responses)

    recorded_call_ids =
      rows
      |> Enum.filter(fn row ->
        latest && row.metadata["tool_result_journal"] == true &&
          row.previous_message_id == latest.id
      end)
      |> Enum.flat_map(& &1.content)
      |> Enum.filter(&Ankole.AIGateway.ResponseItems.output_item?/1)
      |> Enum.map(fn item -> item[Ankole.AIGateway.ResponseItems.pair_identity_field(item)] end)
      |> MapSet.new()

    {:ok,
     %{
       rows: rows,
       responses: responses,
       recorded_call_ids: recorded_call_ids,
       leaf: leaf
     }}
  end

  @max_chain_depth 500
  @scheduled_event_types ~w(check_back_later.wakeup cron.fire)

  @type turn_chain :: %{
          conversation: Conversation.t(),
          final_response: Message.t(),
          response_chain: [Message.t()]
        }

  @type completion :: %{
          conversation: Conversation.t(),
          final_response: Message.t(),
          response_chain: [Message.t()],
          final_text: String.t() | nil,
          clarify_prompt: map() | nil,
          attachments: [map()]
        }

  @type session_key :: %{required(:agent_uid) => String.t(), required(:session_id) => String.t()}

  @doc false
  @spec ensure_and_lock_conversation_in_tx(
          module(),
          String.t(),
          String.t(),
          Signal.t()
        ) ::
          {:ok, Conversation.t()} | {:error, term()}
  def ensure_and_lock_conversation_in_tx(
        repo,
        subject_uid,
        conversation_key,
        %Signal{} = signal
      ) do
    with {:ok, origin} <- conversation_origin(repo, signal) do
      ensure_and_lock_active_conversation(
        repo,
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
    Repo
    |> AIGateway.list_active_conversations(
      subject_uid: subject_uid,
      conversation_key: conversation_key,
      limit: 1
    )
    |> List.first()
  end

  @doc "Ends model history and records the Session's Brain learning trigger atomically."
  def end_active_conversation_in_tx(repo, subject_uid, session_id, now) do
    with {:ok, conversation} <-
           AIGateway.end_active_conversation_in_tx(repo, subject_uid, session_id, now),
         :ok <- Ankole.Brain.ConversationTriggers.conversation_ended_in_tx(repo, session_id) do
      {:ok, conversation}
    end
  end

  @doc false
  def record_tool_results_and_complete_events_in_tx(
        repo,
        subject_uid,
        current_event_id,
        event_ids,
        request
      ) do
    with %Signal{} = current_event <- repo.get(Signal, current_event_id),
         :ok <-
           Queue.lock_session_in_tx(
             repo,
             current_event.agent_uid,
             current_event.session_id
           ),
         %Signal{} <- Ankole.Signals.lock_signal_in_tx(repo, current_event_id),
         {:ok, target_events} <- lock_target_events(repo, event_ids),
         {:ok, journal} <-
           AIGateway.record_tool_results_in_tx(
             repo,
             subject_uid,
             request,
             %{"completed_signal_ids" => event_ids}
           ),
         :ok <- complete_target_events(repo, target_events, journal.disposition) do
      {:ok, journal}
    else
      nil -> {:error, :signal_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp lock_target_events(repo, event_ids) do
    events = Enum.map(event_ids, &Ankole.Signals.lock_signal_in_tx(repo, &1))

    if Enum.all?(events, &match?(%Signal{}, &1)),
      do: {:ok, events},
      else: {:error, :signal_not_found}
  end

  defp complete_target_events(repo, events, :inserted) do
    now = DateTime.utc_now(:microsecond)

    Enum.reduce_while(events, :ok, fn event, :ok ->
      case Ankole.Sessions.Queue.mark_event_completed_in_tx(repo, event, now) do
        {:ok, %Signal{}} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp complete_target_events(_repo, _events, :existing), do: :ok

  # The `conversation_id: nil` clause covers a non-channel-triggering event
  # (for example, an internal command). Its conversation has no channel or DM
  # to record, so origin stays undeclared rather than forcing a lookup that has
  # nothing to find.
  defp conversation_origin(_repo, %Signal{conversation_id: nil}), do: {:ok, :undeclared}

  defp conversation_origin(repo, %Signal{} = signal) do
    case repo.get_by(PublicConversation, id: signal.conversation_id) do
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
         repo,
         subject_uid,
         conversation_key,
         initial_metadata
       ) do
    with {:ok, conversation} <-
           AIGateway.ensure_conversation_in_tx(
             repo,
             subject_uid,
             conversation_key,
             initial_metadata
           ),
         %Conversation{} = conversation <- AIGateway.lock_conversation(repo, conversation.id) do
      if is_nil(conversation.ended_at) do
        {:ok, conversation}
      else
        ensure_and_lock_active_conversation(
          repo,
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
  @spec daily_reset_candidates_in_tx(module(), DateTime.t(), keyword()) :: [Conversation.t()]
  def daily_reset_candidates_in_tx(repo, %DateTime{} = boundary_at, opts \\ []) do
    limit =
      case Keyword.get(opts, :limit, 1_000) do
        value when is_integer(value) and value > 0 -> value
        _invalid -> 1_000
      end

    Conversation
    |> join(:inner, [conversation], workspace in SessionWorkspace,
      on:
        workspace.agent_uid == conversation.subject_uid and
          workspace.session_id == conversation.conversation_key
    )
    |> where([conversation], is_nil(conversation.ended_at))
    |> where([conversation], conversation.inserted_at < ^boundary_at)
    |> where(
      [_conversation, workspace],
      is_nil(workspace.conversation_id) or
        workspace.conversation_id not in subquery(Ankole.Conversations.native_ids_query())
    )
    |> where(
      [conversation],
      not like(
        conversation.conversation_key,
        ^"#{BackgroundAgentJobs.job_session_prefix()}%"
      )
    )
    |> order_by(
      [conversation],
      asc: conversation.subject_uid,
      asc: conversation.conversation_key
    )
    |> limit(^limit)
    |> lock("FOR UPDATE")
    |> repo.all()
  end

  @doc false
  @spec publish_failed_response(Message.t() | nil) :: :ok | {:error, term()}
  def publish_failed_response(nil), do: :ok

  def publish_failed_response(%Message{} = response) do
    error = Map.get(response.metadata || %{}, "error", %{"code" => "response_failed"})
    AIGateway.publish_terminal_event(response, :response_failed, %{error: error})
  end

  @doc "Returns Message IDs read by model calls owned by this Signal."
  def read_message_ids_in_tx(repo, %Signal{} = signal) do
    case active_conversation(signal.agent_uid, signal.session_id) do
      nil ->
        []

      conversation ->
        {:ok, rows} =
          AIGateway.list_conversation_responses_in_tx(repo, signal.agent_uid, conversation.id)

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
          module(),
          String.t(),
          String.t(),
          String.t(),
          DateTime.t()
        ) :: {:ok, map()} | {:error, term()}
  def delete_visible_turn_suffix_in_tx(
        repo,
        subject_uid,
        conversation_key,
        signal_id,
        %DateTime{} = now
      ) do
    case AIGateway.active_conversation_for_update(repo, subject_uid, conversation_key) do
      %Conversation{} = conversation ->
        delete_visible_turn_suffix(repo, conversation, signal_id, now)

      nil ->
        {:ok, suffix_delete_noop(:conversation_not_found)}
    end
  end

  @doc false
  @spec retract_visible_turn_suffix_in_tx(
          module(),
          String.t(),
          String.t(),
          String.t(),
          DateTime.t(),
          keyword()
        ) :: {:ok, map()} | {:error, term()}
  def retract_visible_turn_suffix_in_tx(
        repo,
        subject_uid,
        conversation_key,
        signal_id,
        %DateTime{} = now,
        opts \\ []
      ) do
    case AIGateway.active_conversation_for_update(repo, subject_uid, conversation_key) do
      %Conversation{} = conversation ->
        retract_visible_turn_suffix(repo, conversation, signal_id, now, opts)

      nil ->
        {:ok, suffix_retraction_noop(:conversation_not_found)}
    end
  end

  @doc """
  Loads and validates the immutable Responses facts named by turn completion,
  then projects the reply content from them. The turn commit validates whether
  that projection is valid for the Signal, including an empty projection.

  The database read happens before the Session transaction. Terminal AIGateway
  rows are immutable, while the later Session transaction owns all fence checks
  and provider-visible side effects.
  """
  @spec load_turn_completion(RunRef.t(), String.t()) ::
          {:ok, completion()} | {:error, term()}
  def load_turn_completion(
        %{agent_uid: _, session_id: _, signal_id: _} = turn_ref,
        final_response_id
      ) do
    with {:ok, turn_chain} <- load_turn_chain(turn_ref, final_response_id),
         {:ok, projection} <-
           project_completion(
             turn_ref.agent_uid,
             turn_chain.response_chain,
             turn_chain.final_response,
             Ankole.Conversations.ExternalTarget.origin(turn_chain.conversation)
           ) do
      {:ok, Map.merge(turn_chain, projection)}
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

  defp delete_visible_turn_suffix(repo, %Conversation{} = conversation, signal_id, now) do
    with {:ok, responses} <-
           AIGateway.list_conversation_responses_in_tx(
             repo,
             conversation.subject_uid,
             conversation.id,
             statuses: ["complete", "generating"],
             lock: true
           ) do
      complete_responses = Enum.filter(responses, &(&1.status == "complete"))

      case select_visible_signal_suffix(complete_responses, signal_id) do
        {:noop, reason} ->
          {:ok, suffix_delete_noop(reason)}

        {:ok, suffix} ->
          generating_responses =
            Enum.filter(responses, fn response ->
              response.status == "generating" and
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
                   repo,
                   conversation.subject_uid,
                   generating_responses,
                   error,
                   now
                 ),
               {:ok, deletion} <-
                 AIGateway.hard_delete_visible_suffix_in_tx(
                   repo,
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
         repo,
         %Conversation{} = conversation,
         signal_id,
         now,
         opts
       ) do
    with {:ok, responses} <-
           AIGateway.list_conversation_responses_in_tx(
             repo,
             conversation.subject_uid,
             conversation.id,
             statuses: ["complete"],
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
              repo,
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

      response.type == "checkpoint" ->
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

  defp fail_response_rows_in_tx(repo, subject_uid, responses, error, now) do
    Enum.reduce_while(responses, {:ok, []}, fn response, {:ok, failed} ->
      case AIGateway.fail_generating_response_in_tx(
             repo,
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

  defp ordinary_response?(%Message{type: "message"}), do: true
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

      final.type != "message" ->
        {:error, :final_response_not_message}

      final.status != "complete" ->
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
    message.subject_uid != turn_ref.agent_uid or message.status != "complete"
  end

  defp chain_depth_exceeded?(turn_chain) do
    length(turn_chain) == @max_chain_depth and
      match?(
        %Message{previous_message_id: previous} when not is_nil(previous),
        List.last(turn_chain)
      )
  end

  defp project_completion(subject_uid, turn_chain, final_response, origin) do
    source_items =
      turn_chain
      |> Enum.reverse()
      |> Enum.flat_map(&message_items/1)
      |> dedupe_function_call_outputs()

    final_text = Text.visible_text(final_response.content)

    with {:ok, clarify_prompt} <- ClarifyPrompt.from_response_items(source_items),
         {:ok, attachments} <- Attachment.attachments_from_response_items(source_items),
         {:ok, generated_image_attachments} <-
           materialize_generated_images(subject_uid, turn_chain, origin),
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

  defp materialize_generated_images(subject_uid, turn_chain, origin) do
    turn_chain
    |> Enum.reverse()
    |> Enum.flat_map(&generated_image_items/1)
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn
      %{"id" => image_id}, {:ok, attachments, seen} when is_binary(image_id) ->
        if MapSet.member?(seen, image_id) do
          {:cont, {:ok, attachments, seen}}
        else
          case materialize_generated_image(subject_uid, image_id, origin) do
            {:ok, attachment} ->
              {:cont, {:ok, [attachment | attachments], MapSet.put(seen, image_id)}}

            {:error, _reason} = error ->
              {:halt, error}
          end
        end

      _item, _acc ->
        {:halt, {:error, :invalid_completed_image_generation_call}}
    end)
    |> case do
      {:ok, attachments, _seen} -> {:ok, Enum.reverse(attachments)}
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
  defp materialize_generated_image(subject_uid, image_id, origin) do
    with {:ok, %Artifact{} = artifact} <-
           generated_image_artifact(subject_uid, image_id),
         {:ok, extension} <- generated_image_extension(image_id, artifact.mime_type),
         filename = "#{Artifacts.public_id(artifact)}.#{extension}",
         {:ok, file} <- store_generated_image(subject_uid, image_id, filename, artifact, origin) do
      {:ok,
       %{
         "path" => file.path,
         "blob_ref" => Base.encode16(file.sha256, case: :lower),
         "name" => filename,
         "mime_type" => artifact.mime_type,
         "size" => file.size
       }}
    end
  end

  defp generated_image_artifact(subject_uid, image_id) do
    case Artifacts.get_generated_image(subject_uid, image_id, payload?: true) do
      {:ok, %Artifact{} = artifact} ->
        {:ok, artifact}

      {:error, reason} ->
        {:error, {:generated_image_artifact_unavailable, image_id, reason}}
    end
  end

  defp generated_image_extension(_image_id, "image/png"), do: {:ok, "png"}
  defp generated_image_extension(_image_id, "image/jpeg"), do: {:ok, "jpg"}
  defp generated_image_extension(_image_id, "image/webp"), do: {:ok, "webp"}
  defp generated_image_extension(_image_id, "image/gif"), do: {:ok, "gif"}

  defp generated_image_extension(image_id, mime_type),
    do: {:error, {:unsupported_generated_image_mime_type, image_id, mime_type}}

  defp store_generated_image(agent_uid, image_id, filename, %Artifact{} = artifact, origin) do
    channel_id = if origin, do: origin.id

    with {:ok, %{sha256: sha256}} <- Files.store(artifact.payload),
         {:ok, %{files: [file]}} <-
           Files.commit(agent_uid, [
             %{
               path:
                 Files.chat_path(channel_id, Files.content_path("generated", sha256, filename)),
               sha256: sha256,
               source: "generated",
               conversation_id: channel_id,
               content_type: artifact.mime_type
             }
           ]) do
      {:ok, file}
    else
      {:error, reason} -> {:error, {:generated_image_materialization_failed, image_id, reason}}
    end
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

  defp response_id(%Message{id: id}), do: "resp_#{id}"

  defp generating_responses_for_signal_in_tx(repo, session_key, signal_id) do
    case AIGateway.active_conversation_for_update(
           repo,
           session_key.agent_uid,
           session_key.session_id
         ) do
      %Conversation{} = conversation ->
        case AIGateway.list_conversation_responses_in_tx(
               repo,
               session_key.agent_uid,
               conversation.id,
               statuses: ["generating"],
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
  def retract_generating_turn_in_tx(repo, session_key, signal_id, now, reason)
      when is_binary(reason) do
    generating_responses_for_signal_in_tx(repo, session_key, signal_id)
    |> Enum.reduce_while({:ok, []}, fn response, {:ok, retracted} ->
      case AIGateway.retract_generating_response_in_tx(
             repo,
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
  def exact_turn_retryable_in_tx(repo, session_key, signal_id) do
    case AIGateway.active_conversation_for_update(
           repo,
           session_key.agent_uid,
           session_key.session_id
         ) do
      %Conversation{} = conversation ->
        case AIGateway.list_conversation_responses_in_tx(
               repo,
               session_key.agent_uid,
               conversation.id,
               statuses: ["generating", "complete", "error"],
               lock: true
             ) do
          {:ok, responses} ->
            responses
            |> Enum.filter(&(signal_id in response_signal_ids(&1)))
            |> Enum.all?(fn response ->
              exact_response_owner?(response, signal_id) and
                (response.status != "error" or response_replay_safe?(response))
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
