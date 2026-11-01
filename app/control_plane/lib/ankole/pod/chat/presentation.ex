defmodule Ankole.Pod.Chat.Presentation do
  @moduledoc "The browser projection of a room, its members, and its execution history."
  require Ash.Expr
  alias Ankole.Conversations.{ModelPreferences, NativeRoom}

  def detail(detail) do
    artifacts = detail.artifacts
    saved = detail.saved_pages
    assistant_names = detail.assistant_names

    messages =
      Enum.map(
        detail.messages,
        &Map.put(
          message_json(
            &1,
            detail.interaction_states,
            Map.get(detail, :action_card_states, %{}),
            assistant_names
          ),
          :savedPages,
          Map.get(saved, &1.id, [])
        )
      )

    queues =
      Enum.map(detail.agents, fn agent ->
        inputs = Enum.filter(detail.pending_inputs, &(&1.agent_uid == agent.uid))

        %{
          agentUID: agent.uid,
          retryableMessageID: detail.retryable_message_ids[agent.uid],
          queueVersion: Map.fetch!(detail.queue_versions, agent.uid),
          paused: queue_paused?(detail.conversation, agent.uid),
          workStatus: %{
            state: detail.statuses[agent.uid].state,
            retryAt: timestamp(detail.statuses[agent.uid].retry_at)
          },
          inputs:
            Enum.map(inputs, &queued_input(&1, detail.queued_messages, detail.mention_names))
        }
      end)

    latest_input = detail.latest_input

    %{
      conversation: conversation(detail),
      artifacts: room_artifacts(detail.conversation, artifacts, saved),
      messages: messages,
      olderMessagesBeforeSeq: detail.older_messages_before_seq,
      removedMessageIDs: detail.removed_message_ids,
      messageRange: %{
        firstSeq: detail.message_range.first_seq,
        lastSeq: detail.message_range.last_seq
      },
      pendingQueues: queues,
      latestInput:
        if(latest_input,
          do: %{
            messageID: latest_input.id,
            authorUID: latest_input.author_uid,
            agentUIDs: detail.latest_input_agent_uids
          }
        ),
      activities: detail.activities,
      pendingInteractions: pending_interactions(detail),
      linkedRuns: linked_runs(detail)
    }
  end

  def conversations(details), do: Enum.map(details, &conversation/1)

  def conversation(
        %{conversation: conversation, participants: participants, viewer: viewer} =
          detail
      ) do
    members = Enum.reject(participants, &(&1.role == :observer))

    projected =
      Enum.map(members, fn member ->
        principal = Map.fetch!(detail.member_principals, member.principal_uid)

        Map.merge(
          project_agent(principal, principal.agent, detail.member_names[principal.uid]),
          %{
            canChat: MapSet.member?(detail.callable_agents, principal.uid),
            role: to_string(member.role),
            mayIntervene: member.may_intervene,
            modelProfile:
              if(member.role == :agent, do: ModelPreferences.logical(conversation, principal.uid))
          }
        )
      end)

    %{
      id: conversation.id,
      title: conversation.title,
      pageID: conversation.page_id,
      roomMode: conversation.room_mode,
      accessScope: conversation.native_access_scope,
      createdBy: conversation.created_by,
      canDelete: detail.owner?,
      canManage: detail.owner?,
      titleCustomized: conversation.title_customized,
      lastMessageSeq: conversation.sequence_high_water,
      viewer: %{
        uid: detail.viewer_uid,
        pinned: (viewer && not is_nil(viewer.pinned_at)) || false,
        muted: (viewer && viewer.muted) || false,
        lastReadSeq: (viewer && viewer.last_read_seq) || 0
      },
      agents: Enum.filter(projected, &(&1.type == "agent")),
      participants: projected,
      agent:
        case Map.get(detail, :agent) do
          nil ->
            nil

          principal ->
            project_agent(principal, principal.agent, detail.member_names[principal.uid])
        end,
      lastActivityAt: timestamp(conversation.last_activity_at),
      rowStatus: row_status(detail)
    }
  end

  def agent(principal) do
    agent = if principal.type == :agent, do: Ankole.Principals.get_agent_record!(principal.uid)
    project_agent(principal, agent, NativeRoom.display_name(principal))
  end

  defp project_agent(principal, agent, name) do
    %{
      uid: principal.uid,
      displayName: name,
      avatarURL: principal.avatar_url,
      type: to_string(principal.type),
      agentType: if(agent, do: to_string(agent.type)),
      role: if(agent, do: agent.role),
      aliases:
        if(agent && agent.type == :personal_assistant,
          do: Ankole.Principals.assistant_aliases(principal),
          else: []
        ),
      active: principal.status == :active,
      mayIntervene: false,
      modelProfile: nil
    }
  end

  defp row_status(%{conversation: conversation, agents: agents, viewer: viewer} = detail) do
    cond do
      Enum.any?(
        agents,
        &(detail.statuses[&1.uid].state in [
            :running,
            :retrying
          ])
      ) ->
        "streaming"

      pending_interactions(detail) != [] or Map.get(detail, :has_prepared_action_card?, false) ->
        "waiting_choice"

      Enum.any?(detail.linked_jobs, &(&1.status in [:queued, :running, :waiting_on_user])) or
          Enum.any?(detail.linked_workflows, &(&1.status == :running)) ->
        "running_background"

      not is_nil(viewer) and not viewer.muted and
          conversation.sequence_high_water > viewer.last_read_seq ->
        "unread"

      true ->
        "idle"
    end
  end

  defp queue_paused?(conversation, uid),
    do: conversation.metadata["queue_paused:" <> uid] == true

  defp queued_input(input, messages, names),
    do: %{
      messageID: input.message_id,
      agentUID: input.agent_uid,
      authorUID: input.human_uid,
      text: input.data["text"] || "",
      attachments: attachments_with_positions(get_in(input.data, ["entry", "attachments"]) || []),
      links: Map.get(messages, input.message_id, %{links: []}).links,
      mentions:
        Enum.map(Map.get(messages, input.message_id, %{mentions: []}).mentions, fn mention ->
          %{
            type: mention["type"],
            uid: mention["uid"],
            displayName: mention["displayName"] || names[mention["uid"]]
          }
        end),
      modelProfile: input.data["model_profile"] || "primary",
      deliveryMode: input.data["delivery_mode"] || "steer"
    }

  defp message_json(message, interactions, action_cards, assistant_names) do
    rich = message.rich_content || %{}

    rich =
      case rich["clarify"] do
        %{} = clarify ->
          Map.put(
            rich,
            "clarify",
            Map.merge(clarify, Map.get(interactions, message.id, %{"state" => "superseded"}))
          )

        _ ->
          rich
      end

    rich =
      case rich["action_card"] do
        %{} = card ->
          Map.put(
            rich,
            "action_card",
            Map.merge(card, Map.get(action_cards, message.id, %{}))
          )

        _ ->
          rich
      end

    %{
      id: message.id,
      seq: message.seq,
      authorType: to_string(message.author_type),
      authorUID: message.author_uid,
      authorDisplayName: assistant_names[message.author_uid] || message.author_display_name || "",
      authorArchived: message.author_type == :agent and is_nil(message.author_uid),
      kind: to_string(message.kind),
      text: message.text || "",
      links: message.links,
      mentions:
        Enum.map(message.mentions, fn mention ->
          case assistant_names[mention["uid"]] do
            nil -> mention
            name -> Map.put(mention, "displayName", name)
          end
        end),
      richContent: rich,
      attachments: attachments_with_positions(message.attachments),
      createdAt: timestamp(message.created_at),
      signalID: message.signal_id,
      replyToMessageID: message.reply_to_message_id
    }
  end

  defp pending_interactions(detail) do
    detail.pending_questions
    |> Enum.sort_by(& &1.seq)
    |> Enum.flat_map(fn message ->
      clarify = message.rich_content["clarify"]

      case Map.merge(
             clarify,
             Map.get(detail.interaction_states, message.id, %{"state" => "superseded"})
           ) do
        %{"state" => "pending"} = pending ->
          [Map.merge(pending, %{"messageID" => message.id, "agentUID" => message.author_uid})]

        _ ->
          []
      end
    end)
  end

  defp room_artifacts(conversation, messages, saved) do
    page_ids =
      Enum.flat_map(messages, fn message ->
        referenced = for %{"kind" => "page", "id" => id} <- message.links, do: id
        referenced ++ Enum.map(Map.get(saved, message.id, []), & &1.id)
      end)

    %{
      pageIDs: Enum.uniq(Enum.reject([conversation.page_id | page_ids], &is_nil/1)),
      attachments:
        for message <- messages, message.attachments != [] do
          %{messageID: message.id, attachments: attachments_with_positions(message.attachments)}
        end
    }
  end

  defp attachments_with_positions(attachments),
    do: Enum.with_index(attachments, &Map.put(&1, "position", &2))

  def execution(actor, id, kind, run_id, cursor \\ nil) do
    Ankole.Repo.transact_repeatable_read_only(fn ->
      with {:ok, _room} <- Ankole.Conversations.visible_native_conversation(actor, id),
           run when not is_nil(run) <- execution_run(kind, run_id),
           true <- linked_to_room?(run, id) do
        execution_page(run, kind, cursor)
      else
        false -> {:error, :execution_not_found}
        nil -> {:error, :execution_not_found}
        error -> error
      end
    end)
  end

  defp linked_runs(detail) do
    id = detail.conversation.id

    agents =
      detail.participants
      |> Enum.filter(&(&1.role == :agent))
      |> MapSet.new(& &1.principal_uid)

    Enum.map(
      Enum.filter(detail.linked_jobs, &linked_to_room?(&1, id, agents, detail.source_signals)),
      &run(&1, "background_agent_job", detail.source_signals[&1.source_signal_id])
    ) ++
      Enum.map(
        Enum.filter(
          detail.linked_workflows,
          &linked_to_room?(&1, id, agents, detail.source_signals)
        ),
        &run(&1, "workflow", detail.source_signals[&1.source_signal_id])
      )
  end

  defp execution_run(:background_agent_job, id), do: Ankole.BackgroundAgentJobs.get_job(id)
  defp execution_run(:workflow, id), do: Ankole.Workflow.get_run!(id)

  defp linked_to_room?(run, id, agents \\ nil, sources \\ nil) do
    member? =
      if agents,
        do: MapSet.member?(agents, run.agent_uid),
        else:
          match?(
            %Ankole.Conversations.Participant{role: :agent},
            NativeRoom.participant(id, run.agent_uid)
          )

    run.owner_session_id == Ankole.Sessions.Key.conversation(id) and
      (member? or historical_source?(run, id, sources))
  end

  defp historical_source?(run, id, sources) do
    source =
      if sources,
        do: sources[run.source_signal_id],
        else: run.source_signal_id && Ankole.Signals.get_signal!(run.source_signal_id)

    match?(%{conversation_id: ^id, agent_uid: uid} when uid == run.agent_uid, source)
  end

  defp execution_page(job, :background_agent_job, cursor) do
    with {:ok, page} <- Ankole.BackgroundAgentJobs.console_turn_page(job, cursor) do
      logs =
        Enum.map_join(page.turns, "\n\n", fn turn ->
          messages = get_in(turn, [:trajectory, "messages"]) || []
          visible = Enum.map_join(messages, "\n\n", &execution_message/1)

          "### #{execution_time(turn.started_at)} · #{execution_label(turn.kind)} · #{execution_label(turn.status)}\n\n" <>
            visible
        end)

      result = if is_nil(cursor) and is_map(job.result), do: json_block(job.result)
      {:ok, %{text: join_text([result, logs]), nextCursor: page.next_cursor}}
    else
      {:error, :invalid_background_agent_job_trajectory_cursor} ->
        {:error, :invalid_execution_cursor}

      {:error, :background_agent_job_trajectory_cursor_stale} ->
        {:error, :invalid_execution_cursor}

      error ->
        error
    end
  end

  defp execution_page(workflow, :workflow, cursor) do
    with {:ok, after_seq} <- workflow_cursor(cursor) do
      filter = Ash.Expr.expr(run_id == ^workflow.id and call_seq > ^after_seq)

      calls =
        Ankole.Workflow.list_agent_calls!(
          query: [filter: filter, sort: [call_seq: :asc], limit: 51]
        )

      selected = Enum.take(calls, 50)

      logs =
        Enum.map_join(selected, "\n\n", fn call ->
          "### #{call.label || "Call #{call.call_seq}"} · #{execution_label(call.status)}\n\n" <>
            json_block(call.result || call.error)
        end)

      result = if is_nil(cursor), do: workflow.result_text
      next = if length(calls) > 50, do: to_string(List.last(selected).call_seq)
      {:ok, %{text: join_text([result, logs]), nextCursor: next}}
    end
  end

  defp workflow_cursor(nil), do: {:ok, -1}

  defp workflow_cursor(cursor) do
    case Integer.parse(cursor) do
      {value, ""} when value >= 0 -> {:ok, value}
      _ -> {:error, :invalid_execution_cursor}
    end
  end

  defp execution_message(%{"role" => role} = message) when role in ["assistant", "tool"] do
    if message["channel"] == "analysis" do
      ""
    else
      content = visible_content(message["content"])

      tools =
        Enum.map_join(message["tool_calls"] || [], "\n\n", fn call ->
          function = call["function"]
          "**#{function["name"]}**\n\n" <> json_block(function["arguments"])
        end)

      join_text([content, tools])
    end
  end

  defp execution_message(_message), do: ""
  defp visible_content(text) when is_binary(text), do: text

  defp visible_content(blocks) when is_list(blocks) do
    for block <- blocks,
        block["type"] in ["text", "output_text"],
        is_binary(block["text"]),
        into: "",
        do: block["text"] <> "\n"
  end

  defp visible_content(_content), do: ""
  defp json_block(value), do: "```json\n#{Ankole.JSON.encode!(value)}\n```"
  defp join_text(parts), do: Enum.join(Enum.reject(parts, &(&1 in [nil, ""])), "\n\n")
  defp execution_time(%DateTime{} = value), do: Calendar.strftime(value, "%Y-%m-%d %H:%M:%S UTC")
  defp execution_time(nil), do: "Time unavailable"

  defp execution_time(value) when is_binary(value) do
    {:ok, timestamp, _offset} = DateTime.from_iso8601(value)
    execution_time(timestamp)
  end

  defp execution_label(value),
    do: value |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp run(value, kind, source),
    do: %{
      kind: kind,
      id: to_string(value.id),
      title: value.title,
      status: to_string(value.status),
      agentUID: value.agent_uid,
      sourceSignalID: value.source_signal_id,
      sourceMessageID: source && source.message_id,
      createdAt: timestamp(value.inserted_at),
      updatedAt: timestamp(value.updated_at)
    }

  defp timestamp(nil), do: nil
  defp timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)
end
