defmodule Ankole.SignalsGateway.AIGatewayLink do
  @moduledoc """
  One-way adapter from SignalsGateway Actor semantics to generic AIGateway data.

  `actor_event_id` is opaque client metadata to AIGateway. This module is the
  only place that interprets it when correlating a completed worker turn with
  its immutable Response chain.
  """

  import Ecto.Query, warn: false

  alias Ankole.AIGateway
  alias Ankole.AIGateway.Artifacts
  alias Ankole.AIGateway.Schemas.Conversation
  alias Ankole.AIGateway.Schemas.Artifact
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.AIGateway.StatefulLifecycle
  alias Ankole.AIGateway.StatefulResponses
  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.Principals
  alias Ankole.Repo
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.Actors
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorSessionWorkspace
  alias Ankole.SignalsGateway.AIReplyText
  alias Ankole.SignalsGateway.Channel
  alias Ankole.SignalsGateway.ClarifyPrompt
  alias Ankole.SignalsGateway.Entry
  alias Ankole.SignalsGateway.ReplyAttachment
  alias Ankole.SignalsGateway
  alias Ankole.WorkerFiles

  @max_chain_depth 500
  @scheduled_event_types ~w(check_back_later.wakeup cron.fire)
  @background_job_lifecycle_event_types ~w(
    background_agent_job.waiting
    background_agent_job.completed
    background_agent_job.failed
  )

  @type completion :: %{
          conversation: Conversation.t(),
          final_response: Message.t(),
          response_chain: [Message.t()],
          final_text: String.t() | nil,
          clarify_prompt: map() | nil,
          attachments: [map()]
        }

  @type actor_key :: %{required(:agent_uid) => String.t(), required(:session_id) => String.t()}

  @type generating_turn :: %{
          required(:response) => Message.t(),
          required(:response_id) => String.t(),
          required(:actor_event_id) => String.t(),
          required(:request_ref_actor_event_ids) => [String.t()]
        }

  @doc false
  @spec ensure_and_lock_conversation_in_tx(
          module(),
          String.t(),
          String.t(),
          ActorEvent.t()
        ) ::
          {:ok, Conversation.t()} | {:error, term()}
  def ensure_and_lock_conversation_in_tx(
        repo,
        subject_uid,
        conversation_key,
        %ActorEvent{} = actor_event
      ) do
    with {:ok, origin} <- conversation_origin(repo, actor_event) do
      ensure_and_lock_active_conversation(
        repo,
        subject_uid,
        conversation_key,
        initial_origin_metadata(origin)
      )
    end
  end

  @doc false
  @spec ensure_conversation_in_tx(module(), String.t(), String.t(), map()) ::
          {:ok, Conversation.t()} | {:error, term()}
  def ensure_conversation_in_tx(repo, subject_uid, conversation_key, metadata \\ %{}),
    do: AIGateway.ensure_conversation_in_tx(repo, subject_uid, conversation_key, metadata)

  @doc false
  @spec successor_origin_metadata(Conversation.t()) :: map()
  def successor_origin_metadata(%Conversation{metadata: metadata}) do
    case Map.get(metadata || %{}, "origin") do
      %{} = origin -> %{"origin" => origin}
      _other -> %{}
    end
  end

  @doc false
  @spec active_conversation_for_update(module(), String.t(), String.t()) ::
          Conversation.t() | nil
  def active_conversation_for_update(repo, subject_uid, conversation_key),
    do: AIGateway.active_conversation_for_update(repo, subject_uid, conversation_key)

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

  @doc false
  @spec record_tool_results(String.t(), map()) :: {:ok, %{body: map()}} | {:error, term()}
  def record_tool_results(subject_uid, request) when is_map(request) do
    {complete_actor_event_ids, request} = Map.pop(request, "complete_actor_event_ids", [])

    with {:ok, complete_actor_event_ids} <-
           normalize_complete_actor_event_ids(complete_actor_event_ids) do
      case complete_actor_event_ids do
        [] ->
          AIGateway.record_tool_results(subject_uid, request)

        ids ->
          record_tool_results_and_complete_events(subject_uid, request, ids)
      end
    end
  end

  def record_tool_results(_subject_uid, _request), do: {:error, :invalid_request_body}

  defp record_tool_results_and_complete_events(subject_uid, request, event_ids) do
    with {:ok, subject_uid} <- Principals.normalize_uid(subject_uid),
         {:ok, current_event_id} <- current_actor_event_id(request),
         {:ok, result} <-
           Repo.transact(fn repo ->
             record_tool_results_and_complete_events_in_tx(
               repo,
               subject_uid,
               current_event_id,
               event_ids,
               request
             )
           end) do
      StatefulResponses.publish_tool_result_events(result.message)
      {:ok, %{body: result.body}}
    end
  end

  defp record_tool_results_and_complete_events_in_tx(
         repo,
         subject_uid,
         current_event_id,
         event_ids,
         request
       ) do
    with %ActorEvent{} = current_snapshot <- repo.get(ActorEvent, current_event_id),
         :ok <- validate_current_event_snapshot(current_snapshot, subject_uid),
         {:ok, target_snapshots} <- target_event_snapshots(repo, event_ids),
         :ok <- validate_target_event_snapshots(target_snapshots, current_snapshot),
         :ok <-
           Actors.lock_actor_session_in_tx(
             repo,
             current_snapshot.agent_uid,
             current_snapshot.session_id
           ),
         %ActorEvent{} = current_event <-
           Actors.lock_actor_event_in_tx(repo, current_event_id),
         :ok <- validate_locked_current_event(current_event, current_snapshot),
         {:ok, target_events} <- lock_target_events(repo, event_ids),
         :ok <- validate_locked_target_events(repo, target_events, current_event),
         {:ok, journal} <-
           StatefulLifecycle.record_tool_results_in_tx(
             repo,
             subject_uid,
             request,
             %{"completed_actor_event_ids" => event_ids}
           ),
         :ok <- validate_journal_event_ids(journal.message, event_ids),
         :ok <- complete_target_events(repo, target_events, journal.disposition) do
      {:ok, journal}
    else
      nil -> {:error, :actor_event_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_complete_actor_event_ids(ids) when is_list(ids) and length(ids) <= 32 do
    ids
    |> Enum.reduce_while({:ok, []}, fn id, {:ok, acc} ->
      case Ecto.UUID.cast(id) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        :error -> {:halt, {:error, :invalid_complete_actor_event_ids}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, normalized |> Enum.uniq() |> Enum.sort()}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_complete_actor_event_ids(_ids),
    do: {:error, :invalid_complete_actor_event_ids}

  defp current_actor_event_id(%{"metadata" => %{"actor_event_id" => actor_event_id}}) do
    case Ecto.UUID.cast(actor_event_id) do
      {:ok, actor_event_id} -> {:ok, actor_event_id}
      :error -> {:error, :invalid_current_actor_event_id}
    end
  end

  defp current_actor_event_id(_request), do: {:error, :invalid_current_actor_event_id}

  defp validate_current_event_snapshot(
         %ActorEvent{agent_uid: subject_uid, input_state: "open", completed_at: nil},
         subject_uid
       ),
       do: :ok

  defp validate_current_event_snapshot(%ActorEvent{}, _subject_uid),
    do: {:error, :invalid_current_actor_event}

  defp target_event_snapshots(repo, event_ids) do
    events =
      ActorEvent
      |> where([event], event.id in ^event_ids)
      |> repo.all()

    if length(events) == length(event_ids),
      do: {:ok, events},
      else: {:error, :actor_event_not_found}
  end

  defp validate_target_event_snapshots(events, current_event) do
    if Enum.all?(events, fn event ->
         event.agent_uid == current_event.agent_uid and
           event.session_id == current_event.session_id and
           event.type in @background_job_lifecycle_event_types
       end) do
      :ok
    else
      {:error, :invalid_actor_event_handoff}
    end
  end

  defp validate_locked_current_event(current_event, snapshot) do
    if current_event.agent_uid == snapshot.agent_uid and
         current_event.session_id == snapshot.session_id and
         current_event.input_state == "open" and is_nil(current_event.completed_at) do
      :ok
    else
      {:error, :invalid_current_actor_event}
    end
  end

  defp lock_target_events(repo, event_ids) do
    events = Enum.map(event_ids, &Actors.lock_actor_event_in_tx(repo, &1))

    if Enum.all?(events, &match?(%ActorEvent{}, &1)),
      do: {:ok, events},
      else: {:error, :actor_event_not_found}
  end

  defp validate_locked_target_events(repo, events, current_event) do
    Enum.reduce_while(events, :ok, fn event, :ok ->
      case validate_locked_target_event(repo, event, current_event) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_locked_target_event(repo, event, current_event) do
    with true <- event.agent_uid == current_event.agent_uid,
         true <- event.session_id == current_event.session_id,
         true <- event.input_state == "open",
         true <- event.type in @background_job_lifecycle_event_types,
         {:ok, identity} <- lifecycle_event_identity(event),
         %Job{} = job <- lock_handoff_job(repo, event.agent_uid, identity.job_id),
         true <- job.owner_session_id == event.session_id,
         true <- job.attempts == identity.attempt,
         true <- job.status == identity.status do
      :ok
    else
      _invalid -> {:error, :invalid_actor_event_handoff}
    end
  end

  defp lifecycle_event_identity(%ActorEvent{} = event) do
    data = get_in(event.payload || %{}, ["data"])

    with %{} <- data,
         job_id when is_integer(job_id) and job_id >= 1000 <- Map.get(data, "job_id"),
         attempt when is_integer(attempt) and attempt >= 0 <- Map.get(data, "attempts"),
         status when is_binary(status) <- Map.get(data, "status"),
         {:ok, expected_type, source_status} <- lifecycle_type_identity(status),
         true <- event.type == expected_type,
         true <-
           event.source_event_id ==
             "background_agent_job:#{job_id}:#{source_status}:#{attempt}" do
      {:ok, %{job_id: job_id, attempt: attempt, status: status}}
    else
      _invalid -> {:error, :invalid_actor_event_handoff}
    end
  end

  defp lifecycle_type_identity("waiting_on_user"),
    do: {:ok, "background_agent_job.waiting", "waiting"}

  defp lifecycle_type_identity("succeeded"),
    do: {:ok, "background_agent_job.completed", "succeeded"}

  defp lifecycle_type_identity("failed"),
    do: {:ok, "background_agent_job.failed", "failed"}

  defp lifecycle_type_identity(_status), do: {:error, :invalid_actor_event_handoff}

  defp lock_handoff_job(repo, agent_uid, job_id) do
    Job
    |> where([job], job.id == ^job_id and job.agent_uid == ^agent_uid)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp validate_journal_event_ids(%Message{} = message, event_ids) do
    if Map.get(message.metadata || %{}, "completed_actor_event_ids") == event_ids,
      do: :ok,
      else: {:error, :tool_result_actor_event_ids_mismatch}
  end

  defp complete_target_events(repo, events, :inserted) do
    if Enum.all?(events, &is_nil(&1.completed_at)) do
      now = DateTime.utc_now(:microsecond)

      Enum.reduce_while(events, :ok, fn event, :ok ->
        case SignalsGateway.mark_actor_event_completed_in_tx(repo, event, now) do
          {:ok, %ActorEvent{}} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    else
      {:error, :actor_event_handoff_state_mismatch}
    end
  end

  defp complete_target_events(_repo, events, :existing) do
    if Enum.all?(events, &match?(%DateTime{}, &1.completed_at)),
      do: :ok,
      else: {:error, :actor_event_handoff_state_mismatch}
  end

  # The `signal_channel_id: nil` clause covers a non-channel-triggering event
  # (for example, an internal command). Its conversation has no channel or DM
  # to record, so origin stays undeclared rather than forcing a lookup that has
  # nothing to find.
  defp conversation_origin(_repo, %ActorEvent{signal_channel_id: nil}), do: {:ok, :undeclared}

  defp conversation_origin(repo, %ActorEvent{} = actor_event) do
    case repo.get(Channel, actor_event.signal_channel_id) do
      %Channel{kind: :im_dm} = channel ->
        with {:ok, peer_uid} <- dm_peer_uid(actor_event, channel) do
          {:ok,
           %{
             "peer_uid" => peer_uid,
             "channel_id" => channel.id,
             "channel_kind" => Atom.to_string(channel.kind)
           }}
        end

      %Channel{} = channel ->
        {:ok,
         %{
           "channel_id" => channel.id,
           "channel_kind" => Atom.to_string(channel.kind)
         }}

      nil ->
        if actor_event.type in @scheduled_event_types do
          {:ok, :undeclared}
        else
          {:error, {:conversation_origin_channel_not_found, actor_event.signal_channel_id}}
        end
    end
  end

  defp dm_peer_uid(%ActorEvent{} = actor_event, %Channel{} = channel) do
    peer_uid =
      get_in(actor_event.payload || %{}, ["data", "entry", "author", "principal_uid"]) ||
        Map.get(channel.metadata || %{}, "dm_peer_principal_uid")

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
    |> join(:inner, [conversation], workspace in ActorSessionWorkspace,
      on:
        workspace.agent_uid == conversation.subject_uid and
          workspace.session_id == conversation.conversation_key
    )
    |> where([conversation], is_nil(conversation.ended_at))
    |> where([conversation], conversation.inserted_at < ^boundary_at)
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
  @spec session_has_generating_response?(module(), actor_key()) :: boolean()
  def session_has_generating_response?(repo, actor_key) do
    case active_conversation_for_update(repo, actor_key.agent_uid, actor_key.session_id) do
      %Conversation{} = conversation ->
        case AIGateway.list_conversation_responses_in_tx(
               repo,
               actor_key.agent_uid,
               conversation.id,
               statuses: ["generating"],
               lock: true
             ) do
          {:ok, responses} -> Enum.any?(responses, &ordinary_response?/1)
          {:error, _reason} -> false
        end

      nil ->
        false
    end
  end

  @doc false
  @spec generating_turn_in_tx(module(), actor_key(), String.t() | nil) ::
          generating_turn() | nil
  def generating_turn_in_tx(_repo, _actor_key, actor_event_id)
      when actor_event_id in [nil, ""],
      do: nil

  def generating_turn_in_tx(repo, actor_key, actor_event_id) do
    repo
    |> generating_responses_for_actor_event_in_tx(actor_key, actor_event_id)
    |> List.first()
    |> case do
      %Message{} = response -> generating_turn(response)
      nil -> nil
    end
  end

  @doc false
  @spec cancel_generating_turn_in_tx(
          module(),
          actor_key(),
          String.t() | nil,
          DateTime.t(),
          term()
        ) :: {:ok, Message.t() | nil} | {:error, term()}
  def cancel_generating_turn_in_tx(repo, actor_key, actor_event_id, now, reason) do
    fail_generating_turns_in_tx(
      repo,
      actor_key,
      actor_event_id,
      now,
      runtime_error(reason, "actor_runtime_cancel")
    )
  end

  @doc false
  @spec retract_generating_turn_in_tx(
          module(),
          actor_key(),
          String.t() | nil,
          DateTime.t(),
          String.t()
        ) :: {:ok, Message.t() | nil} | {:error, term()}
  def retract_generating_turn_in_tx(repo, actor_key, actor_event_id, now, reason)
      when is_binary(reason) do
    responses = generating_responses_for_actor_event_in_tx(repo, actor_key, actor_event_id)

    responses
    |> Enum.reduce_while({:ok, []}, fn response, {:ok, retracted} ->
      case AIGateway.retract_generating_response_in_tx(
             repo,
             actor_key.agent_uid,
             response_id(response),
             reason,
             now
           ) do
        {:ok, %Message{} = response} -> {:cont, {:ok, [response | retracted]}}
        {:ok, :already_terminal} -> {:cont, {:ok, retracted}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, retracted} -> {:ok, List.last(retracted)}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec turn_replay_safe_in_tx(module(), actor_key(), String.t()) :: boolean()
  def turn_replay_safe_in_tx(repo, actor_key, actor_event_id)
      when is_binary(actor_event_id) do
    turn_replay_safe_in_tx(
      repo,
      actor_key,
      actor_event_id,
      ["generating", "complete"],
      false
    )
  end

  @doc false
  @spec exact_turn_replay_safe_in_tx(module(), actor_key(), String.t()) :: boolean()
  def exact_turn_replay_safe_in_tx(repo, actor_key, actor_event_id)
      when is_binary(actor_event_id) do
    turn_replay_safe_in_tx(
      repo,
      actor_key,
      actor_event_id,
      ["generating", "complete", "error"],
      true
    )
  end

  defp turn_replay_safe_in_tx(repo, actor_key, actor_event_id, statuses, exact_actor_event?) do
    case active_conversation_for_update(repo, actor_key.agent_uid, actor_key.session_id) do
      %Conversation{} = conversation ->
        case AIGateway.list_conversation_responses_in_tx(
               repo,
               actor_key.agent_uid,
               conversation.id,
               statuses: statuses,
               lock: true
             ) do
          {:ok, responses} ->
            responses
            |> Enum.filter(&(actor_event_id in response_actor_event_ids(&1)))
            |> Enum.all?(fn response ->
              response_replay_safe?(response) and
                (not exact_actor_event? or exact_response_owner?(response, actor_event_id))
            end)

          {:error, _reason} ->
            false
        end

      nil ->
        true
    end
  end

  @doc false
  @spec fail_generating_turn_in_tx(
          module(),
          actor_key(),
          String.t() | nil,
          DateTime.t(),
          term()
        ) :: {:ok, Message.t() | nil} | {:error, term()}
  def fail_generating_turn_in_tx(repo, actor_key, actor_event_id, now, reason) do
    fail_generating_turns_in_tx(
      repo,
      actor_key,
      actor_event_id,
      now,
      runtime_error(reason, "actor_runtime_cleanup")
    )
  end

  @doc false
  @spec publish_failed_response(Message.t() | nil) :: :ok | {:error, term()}
  def publish_failed_response(nil), do: :ok

  def publish_failed_response(%Message{} = response) do
    error = Map.get(response.metadata || %{}, "error", %{"code" => "response_failed"})
    AIGateway.publish_terminal_event(response, :response_failed, %{error: error})
  end

  @doc false
  @spec actor_event_id(Message.t()) :: String.t() | nil
  def actor_event_id(%Message{} = response), do: response_actor_event_id(response)

  @doc false
  @spec complete_responses_by_actor_event(String.t(), [ActorEvent.t()]) :: %{
          optional(String.t()) => %{
            required(:conversation) => Conversation.t(),
            required(:responses) => [Message.t()]
          }
        }
  def complete_responses_by_actor_event(_agent_uid, []), do: %{}

  def complete_responses_by_actor_event(agent_uid, events) when is_list(events) do
    Enum.reduce(events, %{}, fn %ActorEvent{} = event, acc ->
      case completed_turn_responses(agent_uid, event) do
        {%Conversation{} = conversation, [_ | _] = responses} ->
          Map.put(acc, event.id, %{conversation: conversation, responses: responses})

        nil ->
          acc
      end
    end)
  end

  # A completed turn hangs off the worker-declared completion anchor (ADR-0005),
  # so the chain walk stays inside AIGateway's public Response interface instead
  # of probing its metadata storage layout with cross-context SQL.
  defp completed_turn_responses(
         agent_uid,
         %ActorEvent{final_response_id: final_response_id} = event
       )
       when is_binary(final_response_id) do
    with {:ok, chain} <-
           AIGateway.list_response_chain(agent_uid, final_response_id, @max_chain_depth),
         [%Message{} = anchor | _rest] = turn_chain <- complete_turn_chain(chain, event.id),
         {:ok, %Conversation{} = conversation} <-
           AIGateway.get_conversation(agent_uid, anchor.conversation_id) do
      {conversation, Enum.reverse(turn_chain)}
    else
      _missing -> nil
    end
  end

  defp completed_turn_responses(_agent_uid, %ActorEvent{}), do: nil

  defp complete_turn_chain(chain, actor_event_id) do
    chain
    |> Enum.take_while(&(response_actor_event_id(&1) == actor_event_id))
    |> Enum.filter(&(ordinary_response?(&1) and &1.status == "complete"))
  end

  @doc false
  @spec visible_signal_document_ids(TurnRef.t()) :: [String.t()]
  def visible_signal_document_ids(%TurnRef{} = turn_ref) do
    case active_conversation(turn_ref.agent_uid, turn_ref.session_id) do
      %Conversation{} = conversation ->
        current_response = current_response(turn_ref, conversation)
        visible_chain = visible_response_chain(conversation, current_response)

        metadata_responses =
          [current_response | visible_chain]
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq_by(& &1.id)

        actor_event_ids =
          [
            turn_ref.actor_event_id
            | Enum.flat_map(metadata_responses, &response_actor_event_ids/1)
          ]
          |> Enum.filter(&valid_uuid?/1)
          |> Enum.uniq()

        signal_document_ids(visible_chain, actor_event_ids)

      nil ->
        []
    end
  end

  @doc false
  @spec visible_signal_document_ids(String.t(), String.t()) :: [String.t()]
  def visible_signal_document_ids(agent_uid, session_id)
      when is_binary(agent_uid) and is_binary(session_id) do
    case active_conversation(agent_uid, session_id) do
      %Conversation{} = conversation ->
        visible_chain = visible_response_chain(conversation, nil)

        actor_event_ids =
          visible_chain
          |> Enum.flat_map(&response_actor_event_ids/1)
          |> Enum.filter(&valid_uuid?/1)
          |> Enum.uniq()

        signal_document_ids(visible_chain, actor_event_ids)

      nil ->
        []
    end
  end

  @doc """
  Returns the `{signal_channel_id, source_entry_id}` pairs the visible
  Response chain already delivered to the model.

  This covers the addressed entries and the quoted channel-context messages of
  every actor event in the visible chain, in the exact shape those messages
  carry, so turn delivery can drop a quote the conversation already holds
  without touching the stored event.
  """
  @spec visible_channel_context_refs(String.t(), String.t()) :: MapSet.t()
  def visible_channel_context_refs(agent_uid, session_id)
      when is_binary(agent_uid) and is_binary(session_id) do
    case active_conversation(agent_uid, session_id) do
      %Conversation{} = conversation ->
        actor_event_ids =
          conversation
          |> visible_response_chain(nil)
          |> Enum.flat_map(&response_actor_event_ids/1)
          |> Enum.filter(&valid_uuid?/1)
          |> Enum.uniq()

        actor_event_channel_context_refs(actor_event_ids)

      nil ->
        MapSet.new()
    end
  end

  defp actor_event_channel_context_refs([]), do: MapSet.new()

  defp actor_event_channel_context_refs(actor_event_ids) do
    ActorEvent
    |> where([event], event.id in ^actor_event_ids)
    |> Repo.all()
    |> Enum.flat_map(fn
      %ActorEvent{signal_channel_id: channel_id} = event when is_binary(channel_id) ->
        Enum.map(ActorEvent.source_entry_ids(event), &{channel_id, &1})

      %ActorEvent{} ->
        []
    end)
    |> MapSet.new()
  end

  @doc false
  @spec current_response_row_id(TurnRef.t()) :: Ecto.UUID.t() | nil
  def current_response_row_id(%TurnRef{} = turn_ref) do
    with %Conversation{} = conversation <-
           active_conversation(turn_ref.agent_uid, turn_ref.session_id),
         %Message{id: id} <- current_response(turn_ref, conversation) do
      id
    else
      nil -> nil
    end
  end

  @doc false
  @spec retry_source_in_tx(module(), String.t(), String.t()) ::
          {:ok, map()} | {:error, :conversation_not_found | :retry_source_not_found}
  def retry_source_in_tx(repo, subject_uid, conversation_key) do
    with %Conversation{} = conversation <-
           active_conversation_for_update(repo, subject_uid, conversation_key),
         {:ok, responses} <-
           AIGateway.list_conversation_responses_in_tx(
             repo,
             subject_uid,
             conversation.id,
             statuses: ["complete", "error"]
           ) do
      responses
      |> Enum.take(@max_chain_depth)
      |> Enum.find_value(&retry_source_from_response/1)
      |> case do
        %{text: text} = source when is_binary(text) and text != "" -> {:ok, source}
        _missing -> {:error, :retry_source_not_found}
      end
    else
      nil -> {:error, :conversation_not_found}
      {:error, _reason} -> {:error, :conversation_not_found}
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
        actor_event_id,
        %DateTime{} = now
      ) do
    case active_conversation_for_update(repo, subject_uid, conversation_key) do
      %Conversation{} = conversation ->
        delete_visible_turn_suffix(repo, conversation, actor_event_id, now)

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
        actor_event_id,
        %DateTime{} = now,
        opts \\ []
      ) do
    case active_conversation_for_update(repo, subject_uid, conversation_key) do
      %Conversation{} = conversation ->
        retract_visible_turn_suffix(repo, conversation, actor_event_id, now, opts)

      nil ->
        {:ok, suffix_retraction_noop(:conversation_not_found)}
    end
  end

  @doc """
  Loads and validates the immutable Responses facts named by turn completion.

  The database read happens before the Actor transaction. Terminal AIGateway
  rows are immutable, while the later Actor transaction owns all fence checks
  and provider-visible side effects.
  """
  @spec load_turn_completion(TurnRef.t(), String.t()) ::
          {:ok, completion()} | {:error, term()}
  def load_turn_completion(%TurnRef{} = turn_ref, final_response_id)
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
         {:ok, turn_chain} <- turn_response_chain(chain, turn_ref),
         {:ok, projection} <-
           project_completion(turn_ref.agent_uid, turn_chain, final_response) do
      {:ok,
       Map.merge(projection, %{
         conversation: conversation,
         final_response: final_response,
         response_chain: turn_chain
       })}
    end
  end

  def load_turn_completion(%TurnRef{}, _final_response_id),
    do: {:error, :invalid_final_response_id}

  defp generating_responses_for_actor_event_in_tx(repo, actor_key, actor_event_id) do
    case active_conversation_for_update(repo, actor_key.agent_uid, actor_key.session_id) do
      %Conversation{} = conversation ->
        case AIGateway.list_conversation_responses_in_tx(
               repo,
               actor_key.agent_uid,
               conversation.id,
               statuses: ["generating"],
               lock: true
             ) do
          {:ok, responses} ->
            Enum.filter(responses, fn response ->
              ordinary_response?(response) and
                response_actor_event_id(response) == actor_event_id
            end)

          {:error, _reason} ->
            []
        end

      nil ->
        []
    end
  end

  defp generating_turn(%Message{} = response) do
    metadata = AIGateway.response_metadata(response)

    %{
      response: response,
      response_id: response_id(response),
      actor_event_id: metadata["actor_event_id"],
      request_ref_actor_event_ids: request_ref_actor_event_ids(metadata["request_refs"])
    }
  end

  defp request_ref_actor_event_ids(request_refs) when is_list(request_refs) do
    Enum.flat_map(request_refs, fn
      %{"actor_event_id" => actor_event_id} when is_binary(actor_event_id) -> [actor_event_id]
      %{actor_event_id: actor_event_id} when is_binary(actor_event_id) -> [actor_event_id]
      _ref -> []
    end)
  end

  defp request_ref_actor_event_ids(_request_refs), do: []

  defp fail_generating_turns_in_tx(repo, actor_key, actor_event_id, now, error) do
    responses = generating_responses_for_actor_event_in_tx(repo, actor_key, actor_event_id)

    responses
    |> Enum.reduce_while({:ok, []}, fn response, {:ok, failed} ->
      case AIGateway.fail_generating_response_in_tx(
             repo,
             actor_key.agent_uid,
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
      {:ok, failed} -> {:ok, List.last(failed)}
      {:error, _reason} = error -> error
    end
  end

  defp response_replay_safe?(%Message{content: content}) when is_list(content) do
    Enum.all?(content, fn
      %{"type" => type} when type in ["message", "reasoning"] -> true
      %{type: type} when type in ["message", "reasoning"] -> true
      _item -> false
    end)
  end

  defp response_replay_safe?(%Message{}), do: false

  defp exact_response_owner?(%Message{} = response, actor_event_id) do
    metadata = AIGateway.response_metadata(response)

    response_actor_event_id(response) == actor_event_id and
      request_ref_actor_event_ids(metadata["request_refs"]) == []
  end

  defp runtime_error(reason, stage) do
    %{
      "code" => runtime_reason_code(reason),
      "reason" => inspect(reason),
      "stage" => stage
    }
  end

  defp runtime_reason_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp runtime_reason_code(reason) when is_binary(reason), do: reason
  defp runtime_reason_code(_reason), do: "actor_runtime_cleanup"

  defp retry_source_from_response(%Message{} = response) do
    with actor_event_id when is_binary(actor_event_id) <- response_actor_event_id(response),
         text when is_binary(text) and text != "" <- request_user_text(response.content) do
      %{
        actor_event_id: actor_event_id,
        message_id: response.id,
        status: response.status,
        text: text
      }
    else
      _missing -> nil
    end
  end

  defp retry_source_from_response(_response), do: nil

  defp request_user_text(content) when is_list(content) do
    content
    |> Enum.reverse()
    |> Enum.find_value(&request_user_item_text/1)
  end

  defp request_user_text(_content), do: nil

  defp request_user_item_text(%{"type" => "message", "role" => "user", "content" => content})
       when is_list(content),
       do: message_content_text(content)

  defp request_user_item_text(%{"type" => "message", "role" => "user", "content" => content})
       when is_binary(content),
       do: content

  defp request_user_item_text(%{"role" => "user", "content" => content})
       when is_list(content),
       do: message_content_text(content)

  defp request_user_item_text(%{"role" => "user", "content" => content})
       when is_binary(content),
       do: content

  defp request_user_item_text(_item), do: nil

  defp message_content_text(content) do
    content
    |> Enum.map(fn
      %{"text" => text} when is_binary(text) -> text
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      %{"type" => "input_text", "text" => text} when is_binary(text) -> text
      text when is_binary(text) -> text
      _part -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp delete_visible_turn_suffix(repo, %Conversation{} = conversation, actor_event_id, now) do
    with {:ok, responses} <-
           AIGateway.list_conversation_responses_in_tx(
             repo,
             conversation.subject_uid,
             conversation.id,
             statuses: ["complete", "generating"],
             lock: true
           ) do
      complete_responses = Enum.filter(responses, &(&1.status == "complete"))

      case select_visible_actor_suffix(complete_responses, actor_event_id) do
        {:noop, reason} ->
          {:ok, suffix_delete_noop(reason)}

        {:ok, suffix} ->
          generating_responses =
            Enum.filter(responses, fn response ->
              response.status == "generating" and
                ordinary_response?(response) and
                response_actor_event_id(response) == actor_event_id
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
         actor_event_id,
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
      case select_visible_actor_suffix(responses, actor_event_id) do
        {:noop, reason} ->
          {:ok, suffix_retraction_noop(reason)}

        {:ok, suffix} ->
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

  defp select_visible_actor_suffix(complete_responses, actor_event_id) do
    suffix = visible_actor_suffix(complete_responses, actor_event_id)

    case suffix do
      [] ->
        visible_chain = current_visible_chain(complete_responses)

        reason =
          if Enum.any?(visible_chain, &(response_actor_event_id(&1) == actor_event_id)) do
            :not_visible_tail
          else
            :actor_event_not_visible
          end

        {:noop, reason}

      [_response | _rest] ->
        {:ok, suffix}
    end
  end

  defp visible_actor_suffix(complete_responses, actor_event_id) do
    by_id = Map.new(complete_responses, &{&1.id, &1})
    leaf = visible_leaf(complete_responses)

    take_actor_suffix(leaf, by_id, actor_event_id, MapSet.new())
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

  defp take_actor_suffix(nil, _by_id, _actor_event_id, _seen), do: []

  defp take_actor_suffix(%Message{} = response, by_id, actor_event_id, seen) do
    cond do
      MapSet.member?(seen, response.id) ->
        []

      not ordinary_response?(response) ->
        []

      response_actor_event_id(response) != actor_event_id ->
        []

      true ->
        parent = Map.get(by_id, response.previous_message_id)

        [
          response
          | take_actor_suffix(parent, by_id, actor_event_id, MapSet.put(seen, response.id))
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

  defp current_response(%TurnRef{} = turn_ref, %Conversation{} = conversation) do
    Message
    |> where([response], response.subject_uid == ^turn_ref.agent_uid)
    |> where([response], response.conversation_id == ^conversation.id)
    |> where([response], response.type == "message")
    |> where([response], response.status in ["generating", "complete"])
    |> order_by([response], desc: response.inserted_at, desc: response.id)
    |> Repo.all()
    |> Enum.find(&(response_actor_event_id(&1) == turn_ref.actor_event_id))
  end

  defp visible_response_chain(%Conversation{} = conversation, nil),
    do: StatefulResponses.expand_history(conversation.id)

  defp visible_response_chain(
         %Conversation{} = conversation,
         %Message{status: "complete"} = response
       ) do
    StatefulResponses.expand_history(conversation.id, previous_response_id: response.id)
  end

  defp visible_response_chain(
         %Conversation{} = conversation,
         %Message{status: "generating", previous_message_id: previous_message_id}
       )
       when is_binary(previous_message_id) do
    StatefulResponses.expand_history(conversation.id, previous_response_id: previous_message_id)
  end

  defp visible_response_chain(%Conversation{}, %Message{status: "generating"}), do: []

  defp response_actor_event_ids(%Message{} = response) do
    metadata = AIGateway.response_metadata(response)
    [metadata["actor_event_id"] | request_ref_actor_event_ids(metadata["request_refs"])]
  end

  defp response_document_ids([]), do: []

  defp response_document_ids(responses) do
    response_ids = Enum.map(responses, & &1.id)

    Entry
    |> where([entry], entry.ai_message_id in ^response_ids)
    |> select([entry], entry.document_id)
    |> Repo.all()
  end

  defp signal_document_ids(visible_chain, actor_event_ids) do
    response_document_ids(visible_chain)
    |> Kernel.++(actor_event_document_ids(actor_event_ids))
    |> Enum.uniq()
  end

  defp actor_event_document_ids([]), do: []

  defp actor_event_document_ids(actor_event_ids) do
    source_ids_by_channel =
      ActorEvent
      |> where([event], event.id in ^actor_event_ids)
      |> Repo.all()
      |> Enum.reduce(%{}, fn
        %ActorEvent{signal_channel_id: channel_id} = event, acc when is_binary(channel_id) ->
          source_entry_ids = ActorEvent.source_entry_ids(event)

          Map.update(
            acc,
            channel_id,
            source_entry_ids,
            &(source_entry_ids ++ &1)
          )

        %ActorEvent{}, acc ->
          acc
      end)
      |> Map.new(fn {channel_id, source_entry_ids} ->
        {channel_id, Enum.uniq(source_entry_ids)}
      end)

    predicate =
      Enum.reduce(source_ids_by_channel, dynamic(false), fn
        {_channel_id, []}, predicate ->
          predicate

        {channel_id, source_entry_ids}, predicate ->
          dynamic(
            [entry],
            ^predicate or
              (entry.signal_channel_id == ^channel_id and
                 entry.source_entry_id in ^source_entry_ids)
          )
      end)

    Entry
    |> where(^predicate)
    |> select([entry], entry.document_id)
    |> Repo.all()
  end

  defp valid_uuid?(value) when is_binary(value), do: match?({:ok, _uuid}, Ecto.UUID.cast(value))
  defp valid_uuid?(_value), do: false

  defp response_actor_event_id(%Message{} = response),
    do: AIGateway.response_metadata(response)["actor_event_id"]

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

  defp validate_conversation(%Conversation{} = conversation, %TurnRef{} = turn_ref) do
    cond do
      conversation.subject_uid != turn_ref.agent_uid ->
        {:error, :response_subject_mismatch}

      conversation.conversation_key != turn_ref.session_id ->
        {:error, :response_conversation_mismatch}

      true ->
        :ok
    end
  end

  defp turn_response_chain(chain, %TurnRef{} = turn_ref) when is_list(chain) do
    turn_chain =
      Enum.take_while(chain, fn
        %Message{} = message ->
          AIGateway.response_metadata(message)["actor_event_id"] ==
            turn_ref.actor_event_id

        _message ->
          false
      end)

    cond do
      turn_chain == [] ->
        {:error, :response_actor_event_mismatch}

      Enum.any?(turn_chain, &invalid_chain_row?(&1, turn_ref)) ->
        {:error, :response_chain_scope_mismatch}

      chain_depth_exceeded?(turn_chain) ->
        {:error, :response_chain_too_deep}

      true ->
        {:ok, turn_chain}
    end
  end

  defp invalid_chain_row?(%Message{} = message, %TurnRef{} = turn_ref) do
    message.subject_uid != turn_ref.agent_uid or message.status != "complete"
  end

  defp chain_depth_exceeded?(turn_chain) do
    length(turn_chain) == @max_chain_depth and
      match?(
        %Message{previous_message_id: previous} when not is_nil(previous),
        List.last(turn_chain)
      )
  end

  defp project_completion(subject_uid, turn_chain, final_response) do
    source_items =
      turn_chain
      |> Enum.reverse()
      |> Enum.flat_map(&message_items/1)
      |> dedupe_function_call_outputs()

    final_text = AIReplyText.visible_text(final_response.content)

    with {:ok, clarify_prompt} <- ClarifyPrompt.from_response_items(source_items),
         {:ok, attachments} <- ReplyAttachment.attachments_from_response_items(source_items),
         {:ok, generated_image_attachments} <-
           materialize_generated_images(subject_uid, turn_chain),
         attachments = attachments ++ generated_image_attachments,
         :ok <- require_user_visible_projection(final_text, clarify_prompt, attachments) do
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

  defp materialize_generated_images(subject_uid, turn_chain) do
    turn_chain
    |> Enum.reverse()
    |> Enum.flat_map(&generated_image_items/1)
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn
      %{"id" => image_id}, {:ok, attachments, seen} when is_binary(image_id) ->
        if MapSet.member?(seen, image_id) do
          {:cont, {:ok, attachments, seen}}
        else
          case materialize_generated_image(subject_uid, image_id) do
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

  defp materialize_generated_image(subject_uid, image_id) do
    with {:ok, %Artifact{} = artifact} <-
           generated_image_artifact(subject_uid, image_id),
         {:ok, extension} <- generated_image_extension(image_id, artifact.mime_type),
         public_id = Artifacts.public_id(artifact),
         filename = "#{public_id}.#{extension}",
         relative_path = "generated-images/#{filename}",
         :ok <- write_generated_image(subject_uid, image_id, relative_path, artifact.payload) do
      {:ok,
       %{
         "agent_computer_path" =>
           Ankole.AgentHomePaths.user_files(subject_uid) <> "/#{relative_path}",
         "user_files_relative_path" => relative_path,
         "name" => filename,
         "mime_type" => artifact.mime_type,
         "size" => byte_size(artifact.payload)
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

  defp write_generated_image(agent_uid, image_id, relative_path, payload) do
    lane_path = Ankole.AgentHomePaths.user_files_lane_path(agent_uid, relative_path)

    case WorkerFiles.put("user_files", lane_path, payload) do
      {:ok, _result} -> :ok
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

  defp require_user_visible_projection(final_text, clarify_prompt, attachments) do
    if present_text?(final_text) or is_map(clarify_prompt) or attachments != [] do
      :ok
    else
      {:error, :turn_completion_has_no_user_visible_projection}
    end
  end

  defp present_text?(text) when is_binary(text), do: String.trim(text) != ""
  defp present_text?(_text), do: false

  defp response_id(%Message{id: id}), do: "resp_#{id}"
end
