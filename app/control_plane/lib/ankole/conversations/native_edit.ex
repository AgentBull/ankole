defmodule Ankole.Conversations.NativeEdit do
  @moduledoc false

  require Ash.Query

  alias Ankole.{Principals, Repo, Signals}
  alias Ankole.BackgroundAgentJobs.Control, as: JobControl
  alias Ankole.BackgroundAgentJobs.Lifecycle, as: JobLifecycle
  alias Ankole.BackgroundAgentJobs.Queries, as: JobQueries
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.Workflow.Lifecycle, as: WorkflowLifecycle
  alias Ankole.Workflow.Schemas.Run, as: WorkflowRun
  alias Ankole.Workflow.Slot, as: WorkflowSlot

  alias Ankole.Conversations.{
    ActionCards,
    Conversation,
    Message,
    ModelPreferences,
    Native,
    NativeQueue,
    Peers,
    Queries
  }

  alias Ankole.Conversations.Delivery.Interactions
  alias Ankole.Sessions.{ModelHistory, Queue}
  alias Ankole.Signals.Signal

  @addressed "conversation.message.addressed"
  @live_job_statuses [:queued, :running, :waiting_on_user]

  def edit_last(%Ankole.AuthZ.Actor{} = actor, id, attrs) when is_map(attrs) do
    Repo.transact_top_level(
      fn -> edit_last_in_tx(actor, id, attrs) end,
      after_commit: &publish_committed/1
    )
    |> Native.committed(actor)
  end

  def edit_last(_actor, _id, _attrs), do: {:error, :invalid_request}

  @doc false
  def edit_last_in_tx(%Ankole.AuthZ.Actor{} = actor, id, attrs) do
    Ankole.Pod.lock_tree_in_tx()
    human_uid = Ankole.AuthZ.Actor.uid(actor)

    with {:ok, id} <- Queries.cast_id(id),
         {:ok, command_id} <- Queries.cast_id(Ankole.Attrs.get(attrs, :command_id)),
         {:ok, message_id} <- Queries.cast_id(Ankole.Attrs.get(attrs, :message_id)),
         %Conversation{} = visible <- Native.visible_conversation(actor, id),
         room_agents = Native.room_agents(id),
         %{} = agent <-
           Enum.find(room_agents, &(&1.uid == Ankole.Attrs.get(attrs, :agent_uid))) do
      case NativeQueue.accepted_retry(visible, agent, attrs) do
        {:ok, %Signal{} = existing} ->
          {:ok, idempotent_result(id, agent.uid, existing)}

        {:error, _} = error ->
          error

        {:ok, nil} ->
          execute_revert_edit_in_tx(
            actor,
            human_uid,
            visible,
            room_agents,
            agent,
            command_id,
            message_id,
            attrs
          )
      end
    else
      nil -> {:error, :conversation_not_found}
      error -> error
    end
  end

  defp execute_revert_edit_in_tx(
         actor,
         human_uid,
         visible,
         room_agents,
         agent,
         command_id,
         message_id,
         attrs
       ) do
    id = visible.id
    session_id = Ankole.Sessions.Key.conversation(id)
    peers = Peers.exchanges([id])
    agent_uids = known_agent_uids(session_id, room_agents)

    with {:ok, _} <-
           Principals.lock_principals_in_tx(
             principal_uids_to_lock(human_uid, visible, agent_uids, peers)
           ),
         :ok <- Native.check_human_in_tx(actor),
         :ok <- Native.authorize_agent(actor, agent.uid),
         :ok <- lock_agent_slots_in_tx(agent_uids),
         {:ok, pre_scope} <-
           build_scope(id, session_id, human_uid, agent.uid, room_agents, message_id),
         :ok <- verify_message_cas(pre_scope.target, attrs),
         {:ok, edited_text} <-
           Native.native_text(Ankole.Attrs.get(attrs, :text), pre_scope.target.attachments),
         candidates = linked_work_candidates(session_id, pre_scope.retracted_signal_ids, peers),
         locked_workflows = lock_candidate_workflows_in_tx(candidates.workflows),
         locked_jobs = lock_candidate_jobs_in_tx(candidates.jobs),
         workflow_commits = prepare_workflow_cancels_in_tx(locked_workflows),
         {:ok, job_sessions, job_commits} <-
           prepare_job_stops_in_tx(locked_jobs, actor.principal),
         :ok <-
           Queue.lock_sessions_in_tx(
             session_locks_to_acquire(session_id, agent_uids, peers, job_sessions)
           ),
         workspace_keys =
           Enum.map(agent_uids, &%{agent_uid: &1, session_id: session_id}),
         {:ok, workspaces} <- Ankole.Sessions.lock_workspaces_in_tx(workspace_keys),
         %Conversation{} = conversation <- Native.visible_conversation(actor, id, lock: true) do
      commit_locked_edit_in_tx(%{
        actor: actor,
        human_uid: human_uid,
        conversation: conversation,
        room_agents: room_agents,
        agent_uids: agent_uids,
        agent: agent,
        session_id: session_id,
        command_id: command_id,
        message_id: message_id,
        edited_text: edited_text,
        attrs: attrs,
        workspaces: workspaces,
        workflow_commits: workflow_commits,
        job_commits: job_commits,
        peers: peers
      })
    else
      nil -> {:error, :conversation_not_found}
      error -> error
    end
  end

  defp commit_locked_edit_in_tx(ctx) do
    now = DateTime.utc_now(:microsecond)

    with {:ok, existing_retry} <-
           NativeQueue.accepted_retry(ctx.conversation, ctx.agent, ctx.attrs) do
      if existing_retry do
        {:ok, idempotent_result(ctx.conversation.id, ctx.agent.uid, existing_retry)}
      else
        with :ok <- verify_locked_topology(ctx),
             {:ok, scope} <-
               build_scope(
                 ctx.conversation.id,
                 ctx.session_id,
                 ctx.human_uid,
                 ctx.agent.uid,
                 ctx.room_agents,
                 ctx.message_id
               ) do
          apply_locked_scope_in_tx(ctx, scope, now)
        end
      end
    end
  end

  defp verify_locked_topology(ctx) do
    current_room_agents = Native.room_agents(ctx.conversation.id)
    current_peers = Peers.exchanges([ctx.conversation.id])

    if Enum.map(current_room_agents, & &1.uid) == Enum.map(ctx.room_agents, & &1.uid) and
         known_agent_uids(ctx.session_id, current_room_agents) == ctx.agent_uids and
         Enum.map(current_peers, & &1.id) == Enum.map(ctx.peers, & &1.id) do
      :ok
    else
      {:error, :queue_changed}
    end
  end

  defp apply_locked_scope_in_tx(ctx, scope, now) do
    locked_cards = ActionCards.lock_prepared_for_signals_in_tx(scope.retracted_signal_ids)

    pending_ids =
      Signals.list_signals!(
        query: [
          filter: [{:agent_uid, ctx.agent.uid} | Native.pending_filter(ctx.conversation.id)],
          select: [:id]
        ]
      )
      |> Enum.map(& &1.id)

    locked_signals =
      lock_signals_by_ids_in_tx(Enum.uniq(pending_ids ++ scope.retracted_signal_ids))

    pending_id_set = MapSet.new(pending_ids)

    pending_inputs =
      locked_signals
      |> Enum.filter(&MapSet.member?(pending_id_set, &1.id))
      |> Enum.sort_by(& &1.queue_sequence)

    retracted_signals =
      locked_signals
      |> Enum.filter(&MapSet.member?(scope.retracted_signal_set, &1.id))
      |> Enum.sort_by(& &1.queue_sequence)

    with :ok <-
           NativeQueue.check_queue_version(
             ctx.conversation,
             pending_inputs,
             ctx.attrs,
             ctx.agent.uid
           ),
         :ok <- verify_message_cas(scope.target, ctx.attrs),
         :ok <-
           ModelPreferences.authorize_input(ctx.conversation, ctx.agent.uid, "queue", true),
         {:ok, stopped_workflows} <- commit_workflow_cancels_in_tx(ctx.workflow_commits),
         {:ok, stopped_jobs} <- commit_job_stops_in_tx(ctx.job_commits),
         {:ok, stopped_peer_signals} <-
           stop_matching_peers_in_tx(ctx.peers, scope.retracted_signal_set, ctx.human_uid),
         affected_workspaces =
           Enum.filter(ctx.workspaces, &(&1.agent_uid in scope.affected_agent_uids)),
         :ok <- Ankole.Sessions.fence_workspaces_in_tx(affected_workspaces),
         removed_ids = planned_removed_ids(scope),
         {:ok, command} <-
           record_completed_edit_command_in_tx(
             ctx,
             scope.target_signal.id,
             removed_ids,
             now
           ),
         {:ok, _} <-
           Interactions.supersede_reverted_signals_in_tx(
             retracted_signals,
             command,
             locked_cards,
             now
           ),
         :ok <-
           retract_signals_in_tx(
             retracted_signals,
             MapSet.put(scope.later_human_message_set, scope.target.id),
             now
           ),
         :ok <- retract_model_histories_in_tx(scope, ctx.session_id, now),
         :ok <- maybe_clear_pause_in_tx(ctx.conversation, ctx.agent.uid),
         {:ok, edit_signal} <- accept_edited_signal_in_tx(ctx, scope.target, now),
         session_keys =
           Enum.map(scope.affected_agent_uids, &%{agent_uid: &1, session_id: ctx.session_id}),
         :ok <- enqueue_drivers_in_tx(session_keys, now),
         {:ok, _updated} <- NativeQueue.edit_message_in_tx(scope.target, ctx.attrs, now),
         :ok <- cleanup_reverted_messages_in_tx(scope, now) do
      {:ok,
       %{
         id: ctx.conversation.id,
         event: edit_signal,
         session_key: %{agent_uid: ctx.agent.uid, session_id: ctx.session_id},
         session_keys: session_keys,
         publications: [{ctx.conversation.id, :message}],
         removed_message_ids: removed_ids,
         stopped_jobs: stopped_jobs,
         stopped_workflows: stopped_workflows,
         stopped_peer_signals: stopped_peer_signals
       }}
    end
  end

  defp build_scope(conversation_id, session_id, human_uid, agent_uid, room_agents, message_id) do
    target =
      Message
      |> Ash.Query.filter(
        conversation_id == ^conversation_id and id == ^message_id and not withdrawn
      )
      |> Ash.Query.load(:attachments)
      |> Ankole.Ash.read_one!()

    with %Message{author_type: :human, author_uid: ^human_uid, kind: :message} <- target,
         :ok <- validate_target_agents(target, agent_uid),
         false <- other_human_replied_after?(conversation_id, target.seq, human_uid),
         %Signal{} = target_signal <- oldest_target_signal(conversation_id, target.id, agent_uid) do
      later_messages =
        Message
        |> Ash.Query.filter(conversation_id == ^conversation_id and seq > ^target.seq)
        |> Ankole.Ash.read!()

      later_human = Enum.filter(later_messages, &(&1.author_type == :human))
      later_human_ids = Enum.map(later_human, & &1.id)
      later_non_human = Enum.reject(later_messages, &(&1.author_type == :human))

      signals_by_agent =
        collect_retracted_signals(
          session_id,
          agent_uid,
          room_agents,
          target.id,
          target_signal.queue_sequence,
          later_human_ids
        )

      retracted_signal_ids =
        signals_by_agent
        |> Map.values()
        |> List.flatten()
        |> Enum.uniq()

      extra_replies =
        extra_target_replies(conversation_id, retracted_signal_ids, later_non_human)

      affected_uids =
        [agent_uid | Map.keys(signals_by_agent)]
        |> Enum.uniq()
        |> Enum.sort()

      {:ok,
       %{
         target: target,
         target_signal: target_signal,
         later_human_messages: later_human,
         later_human_message_set: MapSet.new(later_human_ids),
         removable_agent_messages: later_non_human ++ extra_replies,
         signals_by_agent: signals_by_agent,
         retracted_signal_ids: retracted_signal_ids,
         retracted_signal_set: MapSet.new(retracted_signal_ids),
         affected_agent_uids: affected_uids
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :reply_unavailable}
    end
  end

  defp validate_target_agents(message, agent_uid) do
    case NativeQueue.addressed_agent_uids(message) do
      [^agent_uid] -> :ok
      [_first, _second | _rest] -> {:error, :input_already_started}
      _ -> {:error, :reply_unavailable}
    end
  end

  defp other_human_replied_after?(conversation_id, seq, human_uid) do
    Message
    |> Ash.Query.filter(
      conversation_id == ^conversation_id and seq > ^seq and not withdrawn and
        author_type == :human and author_uid != ^human_uid
    )
    |> Ankole.Ash.exists?()
  end

  defp oldest_target_signal(conversation_id, message_id, agent_uid) do
    Signals.list_signals!(
      query: [
        filter: [
          conversation_id: conversation_id,
          message_id: message_id,
          agent_uid: agent_uid,
          type: @addressed
        ],
        sort: [queue_sequence: :asc]
      ]
    )
    |> Enum.reject(&(&1.data["removed"] == true))
    |> List.first()
  end

  defp collect_retracted_signals(
         session_id,
         agent_uid,
         room_agents,
         target_message_id,
         min_queue_seq,
         later_human_ids
       ) do
    primary_ids =
      Signals.list_signals!(
        query: [
          filter: [
            agent_uid: agent_uid,
            session_id: session_id,
            queue_sequence: [greater_than: min_queue_seq - 1]
          ],
          select: [:id]
        ]
      )
      |> Enum.map(& &1.id)

    target_msg_ids =
      Signals.list_signals!(
        query: [
          filter: [
            agent_uid: agent_uid,
            session_id: session_id,
            message_id: target_message_id
          ],
          select: [:id]
        ]
      )
      |> Enum.map(& &1.id)

    base = %{agent_uid => Enum.uniq(primary_ids ++ target_msg_ids)}

    if later_human_ids == [] do
      base
    else
      collect_other_agent_signals(base, session_id, agent_uid, room_agents, later_human_ids)
    end
  end

  defp collect_other_agent_signals(base, session_id, primary_uid, room_agents, later_human_ids) do
    room_agents
    |> Enum.map(& &1.uid)
    |> Enum.reject(&(&1 == primary_uid))
    |> Enum.reduce(base, fn uid, acc ->
      matching =
        Signals.list_signals!(
          query: [
            filter: [
              agent_uid: uid,
              session_id: session_id,
              message_id: [in: later_human_ids]
            ],
            sort: [queue_sequence: :asc],
            select: [:id, :queue_sequence]
          ]
        )

      case matching do
        [] ->
          acc

        [first | _] ->
          ids =
            Signals.list_signals!(
              query: [
                filter: [
                  agent_uid: uid,
                  session_id: session_id,
                  queue_sequence: [greater_than: first.queue_sequence - 1]
                ],
                select: [:id]
              ]
            )
            |> Enum.map(& &1.id)

          Map.put(acc, uid, ids)
      end
    end)
  end

  defp extra_target_replies(_conversation_id, [], _already_selected), do: []

  defp extra_target_replies(conversation_id, retracted_signal_ids, already_selected) do
    selected_ids = MapSet.new(already_selected, & &1.id)

    Message
    |> Ash.Query.filter(
      conversation_id == ^conversation_id and signal_id in ^retracted_signal_ids and
        author_type != :human
    )
    |> Ankole.Ash.read!()
    |> Enum.reject(&MapSet.member?(selected_ids, &1.id))
  end

  defp verify_message_cas(message, attrs) do
    expected_links = Ankole.Attrs.get(attrs, :expected_links)
    expected_mentions = Ankole.Attrs.get(attrs, :expected_mentions)

    if Ankole.Attrs.get(attrs, :expected_text) == (message.text || "") and
         (is_nil(expected_links) or
            NativeQueue.canonical_links(expected_links) ==
              NativeQueue.canonical_links(message.links)) and
         (is_nil(expected_mentions) or
            mention_identities(expected_mentions) == mention_identities(message.mentions)) do
      :ok
    else
      {:error, :queue_changed}
    end
  end

  defp mention_identities(mentions) do
    mentions
    |> NativeQueue.canonical_mentions()
    |> Enum.map(&{&1["type"], &1["uid"]})
  end

  defp known_agent_uids(session_id, room_agents) do
    signal_uids =
      Signals.list_signals!(
        query: [
          filter: [session_id: session_id],
          select: [:agent_uid]
        ]
      )
      |> Enum.map(& &1.agent_uid)

    (Enum.map(room_agents, & &1.uid) ++ signal_uids)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp lock_agent_slots_in_tx(agent_uids) do
    with :ok <- lock_each_slot_in_tx(agent_uids, &JobLifecycle.lock_agent_slots/1) do
      lock_each_slot_in_tx(agent_uids, &WorkflowSlot.lock_agent_slots/1)
    end
  end

  defp lock_each_slot_in_tx(agent_uids, lock_fun) do
    Enum.reduce_while(agent_uids, :ok, fn uid, :ok ->
      case lock_fun.(uid) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp linked_work_candidates(session_id, signal_ids, peers) do
    if signal_ids == [] do
      %{jobs: [], workflows: [], peers: peers}
    else
      signal_set = MapSet.new(signal_ids)
      jobs = linked_jobs_for_signals(session_id, signal_set)

      workflows =
        Ankole.Workflow.list_runs!(
          query: [
            filter: [
              owner_session_id: session_id,
              status: :running,
              source_signal_id: [in: signal_ids]
            ]
          ]
        )
        |> Enum.sort_by(& &1.id)

      %{jobs: jobs, workflows: workflows, peers: peers}
    end
  end

  defp linked_jobs_for_signals(session_id, signal_set) do
    session_jobs =
      Ankole.BackgroundAgentJobs.list_jobs!(
        query: [
          filter: [owner_session_id: session_id]
        ]
      )
      |> Enum.reject(&(get_in(&1.metadata || %{}, ["skill_lesson_reflection"]) == true))

    jobs_by_id = Map.new(session_jobs, &{&1.id, &1})

    session_jobs
    |> Enum.filter(fn job ->
      job.status in @live_job_statuses and job_spawned_from_signals?(job, jobs_by_id, signal_set)
    end)
    |> Enum.sort_by(& &1.id)
  end

  defp job_spawned_from_signals?(job, jobs_by_id, signal_set, seen \\ MapSet.new()) do
    cond do
      MapSet.member?(seen, job.id) ->
        false

      not is_nil(job.source_signal_id) and MapSet.member?(signal_set, job.source_signal_id) ->
        true

      is_integer(job.continued_from_job_id) ->
        case Map.get(jobs_by_id, job.continued_from_job_id) do
          %Job{} = parent ->
            job_spawned_from_signals?(parent, jobs_by_id, signal_set, MapSet.put(seen, job.id))

          nil ->
            false
        end

      true ->
        false
    end
  end

  defp principal_uids_to_lock(human_uid, visible, agent_uids, peers) do
    [
      human_uid,
      visible.created_by
      | agent_uids ++ Enum.map(peers, & &1.peer_target_uid)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp session_locks_to_acquire(session_id, agent_uids, peers, job_sessions) do
    room_sessions = Enum.map(agent_uids, &{&1, session_id})

    peer_sessions =
      Enum.map(peers, &{&1.peer_target_uid, Ankole.Sessions.Key.conversation(&1.id)})

    (room_sessions ++ peer_sessions ++ job_sessions)
    |> Enum.uniq()
  end

  defp lock_candidate_workflows_in_tx(workflows) do
    Enum.flat_map(workflows, fn run ->
      case WorkflowSlot.lock_run(run.id, run.agent_uid) do
        %WorkflowRun{} = locked -> [locked]
        nil -> []
      end
    end)
  end

  defp lock_candidate_jobs_in_tx(jobs) do
    Enum.flat_map(jobs, fn job ->
      case JobQueries.lock_for_agent_in_tx(job.id, job.agent_uid) do
        %Job{} = locked -> [locked]
        nil -> []
      end
    end)
  end

  defp prepare_workflow_cancels_in_tx(workflows) do
    Enum.map(workflows, fn run ->
      {:ok, commit} = WorkflowLifecycle.prepare_cancel_locked_in_tx(run)
      commit
    end)
  end

  defp commit_workflow_cancels_in_tx(commits) do
    Enum.reduce_while(commits, {:ok, []}, fn commit, {:ok, stopped} ->
      case commit.() do
        {:ok, %{noop: true}} -> {:cont, {:ok, stopped}}
        {:ok, value} -> {:cont, {:ok, [value | stopped]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp prepare_job_stops_in_tx(jobs, principal) do
    operator_ref = principal |> Ankole.ActorRef.from_principal() |> to_string()

    Enum.reduce_while(jobs, {:ok, [], []}, fn %Job{} = job, {:ok, sessions, commits} ->
      if job.status in Job.terminal_statuses() do
        {:cont, {:ok, sessions, commits}}
      else
        case JobControl.prepare_stop_locked_in_tx(job, %{
               "agent_uid" => job.agent_uid,
               "cancel_requested_by" => operator_ref,
               "reason" => "Reverted from Pod conversation"
             }) do
          {:ok, job_sessions, commit} ->
            {:cont, {:ok, sessions ++ job_sessions, [commit | commits]}}

          {:error, _} = error ->
            {:halt, error}
        end
      end
    end)
  end

  defp commit_job_stops_in_tx(commits) do
    commits
    |> Enum.reverse()
    |> Enum.reduce_while({:ok, []}, fn commit, {:ok, stopped} ->
      case commit.() do
        {:ok, %{noop: true}} -> {:cont, {:ok, stopped}}
        {:ok, value} -> {:cont, {:ok, [value | stopped]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp stop_matching_peers_in_tx(peers, retracted_signal_set, human_uid) do
    matching =
      Enum.filter(peers, fn peer ->
        MapSet.member?(retracted_signal_set, peer.root_human_signal_id)
      end)

    if matching == [], do: {:ok, []}, else: Peers.stop_all_in_tx(matching, human_uid)
  end

  defp lock_signals_by_ids_in_tx([]), do: []

  defp lock_signals_by_ids_in_tx(ids) do
    Signals.lock_signals_in_tx([id: [in: ids]], sort: [id: :asc])
  end

  defp planned_removed_ids(scope) do
    (Enum.map(scope.later_human_messages, & &1.id) ++
       Enum.map(scope.removable_agent_messages, & &1.id))
    |> Enum.uniq()
  end

  defp record_completed_edit_command_in_tx(ctx, target_signal_id, removed_ids, now) do
    data =
      "edit_last"
      |> NativeQueue.retry_command_data(ctx.message_id, ctx.attrs)
      |> Map.put("command", %{"targetSignalId" => target_signal_id})
      |> Map.put("removed_message_ids", removed_ids)

    with {:ok, command} <-
           Signals.accept_in_tx(%{
             producer: :kernel,
             source: "native-control:" <> ctx.conversation.id,
             id: ctx.command_id,
             type: "command.retry",
             subject: ctx.conversation.id,
             target: %{agent_uid: ctx.agent.uid, conversation_id: ctx.conversation.id},
             sender: ctx.human_uid,
             data: data
           }),
         do: Queue.complete_command_event_in_tx(command, completed_at: now)
  end

  defp retract_signals_in_tx(signals, retracted_human_message_set, now) do
    Enum.reduce_while(signals, :ok, fn signal, :ok ->
      mark_removed? =
        signal.type == @addressed and not is_nil(signal.message_id) and
          MapSet.member?(retracted_human_message_set, signal.message_id)

      with {:ok, signal} <- maybe_mark_signal_removed_in_tx(signal, mark_removed?),
           {:ok, _} <- maybe_complete_live_signal_in_tx(signal, now) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp maybe_mark_signal_removed_in_tx(signal, false), do: {:ok, signal}

  defp maybe_mark_signal_removed_in_tx(%Signal{data: %{"removed" => true}} = signal, true),
    do: {:ok, signal}

  defp maybe_mark_signal_removed_in_tx(signal, true) do
    Signals.update_metadata_signal(signal, %{data: Map.put(signal.data, "removed", true)})
  end

  defp maybe_complete_live_signal_in_tx(%Signal{status: status} = signal, now)
       when status in [:queued, :running],
       do: Queue.mark_event_completed_in_tx(signal, now)

  defp maybe_complete_live_signal_in_tx(signal, _now), do: {:ok, signal}

  defp retract_model_histories_in_tx(scope, session_id, now) do
    Enum.reduce_while(scope.affected_agent_uids, :ok, fn uid, :ok ->
      signal_ids = Map.get(scope.signals_by_agent, uid, [])

      case ModelHistory.retract_from_signals_in_tx(
             uid,
             session_id,
             signal_ids,
             now,
             "conversation.edit"
           ) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp maybe_clear_pause_in_tx(conversation, agent_uid) do
    if conversation.metadata["queue_paused:" <> agent_uid] == true do
      with {:ok, _} <- NativeQueue.put_queue_pause(conversation, agent_uid, false), do: :ok
    else
      :ok
    end
  end

  defp accept_edited_signal_in_tx(ctx, message, now) do
    rich_content = NativeQueue.edited_rich_content(message, ctx.edited_text)

    data =
      %{
        "conversation_id" => ctx.conversation.id,
        "message_id" => message.id,
        "message_ids" => [message.id],
        "author_uid" => message.author_uid,
        "text" => ctx.edited_text,
        "request_context" => Ankole.AuthZ.Actor.request_context(ctx.actor),
        "model_profile" => ModelPreferences.logical(ctx.conversation, ctx.agent.uid)
      }
      |> maybe_put_answered_interaction(rich_content)
      |> maybe_put_attachments_entry(ctx.edited_text, message.attachments)

    Signals.accept_in_tx(%{
      producer: :kernel,
      source: ctx.session_id,
      id: "edit:" <> ctx.command_id,
      type: @addressed,
      subject: ctx.conversation.id,
      target: %{agent_uid: ctx.agent.uid, conversation_id: ctx.conversation.id},
      sender: message.author_uid,
      message_id: message.id,
      time: now,
      available_at: now,
      data: data
    })
  end

  defp maybe_put_answered_interaction(data, rich_content) do
    data =
      case rich_content["answered_interaction_id"] do
        id when is_binary(id) and id != "" -> Map.put(data, "answered_interaction_id", id)
        _ -> data
      end

    Ankole.Attrs.maybe_put(data, "interaction_answer", rich_content["interaction_answer"])
  end

  defp maybe_put_attachments_entry(data, _text, []), do: data

  defp maybe_put_attachments_entry(data, text, attachments),
    do: Map.put(data, "entry", %{"text" => text, "attachments" => attachments})

  defp enqueue_drivers_in_tx(keys, now) do
    Enum.each(keys, fn key ->
      :ok = Ankole.Sessions.Jobs.EnsureDriver.enqueue_in_tx(key, now)
    end)

    :ok
  end

  defp cleanup_reverted_messages_in_tx(scope, now) do
    case planned_removed_ids(scope) do
      [] ->
        :ok

      ids ->
        locked =
          Message
          |> Ash.Query.filter(id in ^ids)
          |> Ash.Query.sort(id: :asc)
          |> Ash.Query.load(:withdrawn)
          |> Ash.Query.lock(:for_update)
          |> Ankole.Ash.read!()

        Enum.reduce_while(locked, :ok, fn message, :ok ->
          preserve_withdrawn_human? =
            MapSet.member?(scope.later_human_message_set, message.id) and message.withdrawn

          with :ok <- Queries.message_changed_in_tx(message, nil, now),
               {:ok, _} <-
                 if(preserve_withdrawn_human?,
                   do: {:ok, message},
                   else: Ankole.Ash.destroy(message, :remove)
                 ) do
            {:cont, :ok}
          else
            error -> {:halt, error}
          end
        end)
    end
  end

  defp idempotent_result(id, agent_uid, existing) do
    key = %{agent_uid: agent_uid, session_id: Ankole.Sessions.Key.conversation(id)}

    %{
      id: id,
      session_key: key,
      session_keys: [key],
      publications: [],
      removed_message_ids: existing.data["removed_message_ids"] || [],
      stopped_jobs: [],
      stopped_workflows: [],
      stopped_peer_signals: []
    }
  end

  defp publish_committed(result) do
    Enum.each(Map.get(result, :stopped_jobs, []), fn stopped ->
      Ankole.BackgroundAgentJobs.Lifecycle.publish_status_commit(stopped)
      Ankole.Sessions.stop_job_turn(stopped.job, stopped.turn)
    end)

    Enum.each(Map.get(result, :stopped_workflows, []), fn stopped ->
      Ankole.Workflow.cleanup_terminal_transition({:ok, stopped})
    end)

    case Map.get(result, :stopped_peer_signals, []) do
      [] -> :ok
      signals -> Signals.publish_committed(signals)
    end

    Native.publish_native_change(result)
  end
end
