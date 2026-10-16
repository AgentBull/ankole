defmodule Ankole.Sessions.SharedConversationTest do
  use Ankole.DataCase, async: false
  import Ecto.Query
  import Ankole.PrincipalsFixtures
  import Ankole.AIGatewayCase, only: [start_response_run: 1]
  alias Ankole.{AIGateway, Repo, Signals}
  alias Ankole.Conversations.{Context, External, Participant}
  alias Ankole.Sessions.{AmbientCuration, ConversationContext}
  alias Ankole.AIGateway.ResponseCommit

  @now ~U[2026-10-14 12:00:00.000000Z]

  setup do
    %{principal: human} = human_fixture()
    %{principal: first} = agent_fixture(%{owner_principal_uid: human.uid})
    %{principal: second} = agent_fixture(%{owner_principal_uid: human.uid})
    conversation = observe_room(first)
    assert observe_room(second).id == conversation.id
    human_message = observe(conversation.id, "human", human.uid, "Current request")

    %{
      human: human,
      first: first,
      second: second,
      conversation: conversation,
      human_message: human_message
    }
  end

  test "each Agent reads the other Agent's reply despite equal Session strings", c do
    first_signal = signal(c, c.first, "conversation.message.addressed")
    second_signal = signal(c, c.second, "conversation.message.addressed")
    first_reply = observe(c.conversation.id, "first", c.first.uid, "Agent A reply", first_signal)

    second_reply =
      observe(c.conversation.id, "second", c.second.uid, "Agent B reply", second_signal)

    first_run = run(c, c.first, first_signal)
    second_run = run(c, c.second, second_signal)
    first_request = ConversationContext.append(first_run, %{"metadata" => %{}, "input" => []})
    second_request = ConversationContext.append(second_run, %{"metadata" => %{}, "input" => []})
    assert first_signal.session_id == second_signal.session_id
    assert Ankole.JSON.encode!(first_request["input"]) =~ second_reply.text
    refute Ankole.JSON.encode!(first_request["input"]) =~ first_reply.text
    assert Ankole.JSON.encode!(second_request["input"]) =~ first_reply.text
    refute Ankole.JSON.encode!(second_request["input"]) =~ second_reply.text

    {:ok, response} =
      start_response_run(%{
        subject_uid: c.first.uid,
        conversation_id: first_run.conversation.id,
        metadata: %{"request_metadata" => first_request["metadata"]}
      })

    {:ok, _} = ResponseCommit.commit_complete(response, [])

    assert ConversationContext.read_seq(c.first.uid, first_run.conversation.id, c.conversation.id) ==
             3

    assert ConversationContext.read_seq(
             c.second.uid,
             second_run.conversation.id,
             c.conversation.id
           ) == 0

    assert Repo.aggregate(Participant, :count) == 2
  end

  test "removing the latest platform message cannot reuse a consumed sequence", c do
    signal = signal(c, c.first, "conversation.message.addressed")
    tail = observe(c.conversation.id, "tail", c.second.uid, "Before removal")
    run = run(c, c.first, signal)
    request = ConversationContext.append(run, %{"metadata" => %{}, "input" => []})

    {:ok, response} =
      start_response_run(%{
        subject_uid: c.first.uid,
        conversation_id: run.conversation.id,
        metadata: %{"request_metadata" => request["metadata"]}
      })

    {:ok, _} = ResponseCommit.commit_complete(response, [])
    assert {:ok, _} = Repo.transact(&External.remove_in_tx(&1, c.conversation.id, "tail"))
    next = observe(c.conversation.id, "next", c.second.uid, "After removal")
    assert next.seq > tail.seq
    assert observe(c.conversation.id, "next", c.second.uid, "After removal").seq == next.seq

    assert Ankole.JSON.encode!(
             ConversationContext.append(run, %{"metadata" => %{}, "input" => []})["input"]
           ) =~ next.text
  end

  test "one Agent's ambient judgment never advances the other Agent's observation", c do
    for agent <- [c.first, c.second] do
      assert {:ok, _} =
               Ankole.SignalsFixtures.raw_binding_fixture(%{
                 agent_uid: agent.uid,
                 name: "room",
                 adapter: "lark",
                 config_ref: "app-config://test",
                 filters: %{},
                 target: %{},
                 unaddressed_group_message_policy: :may_intervene
               })
    end

    signal = signal(c, c.first, "im.message.may_intervene")
    key = %{agent_uid: c.first.uid, session_id: signal.session_id}

    assert {:ok, %{judged_until: @now}} =
             AmbientCuration.record_judgment(
               key,
               signal.id,
               %{action: "NOOP", authority: "NONE", handoff_job_id: nil, reason: "No request"},
               now: @now
             )

    assert AmbientCuration.judged_until(c.first.uid, c.conversation.id) == @now
    assert is_nil(AmbientCuration.judged_until(c.second.uid, c.conversation.id))
    attrs = %{conversation_id: c.conversation.id, provider_thread_id: nil}

    assert Context.ambient_delta_messages(
             attrs,
             [],
             AmbientCuration.judged_until(c.first.uid, c.conversation.id)
           ) == []

    assert Enum.map(
             Context.ambient_delta_messages(
               attrs,
               [],
               AmbientCuration.judged_until(c.second.uid, c.conversation.id)
             ),
             & &1["message_id"]
           ) == [c.human_message.id]
  end

  test "a background edit leaves the active round and consumed history unchanged",
       c do
    input = signal(c, c.first, "conversation.message.addressed")
    # The manual model rows below represent an admitted input.
    input =
      input
      |> Ankole.Signals.Signal.changeset(%{last_attempt_at: @now, attempt_count: 1})
      |> Repo.update!()

    background = observe(c.conversation.id, "background", c.second.uid, "Original background")
    model_run = run(c, c.first, input)

    request =
      ConversationContext.append(model_run, %{
        "metadata" => %{"signal_id" => input.id},
        "input" => []
      })

    {:ok, previous} =
      start_response_run(%{
        subject_uid: c.first.uid,
        conversation_id: model_run.conversation.id,
        metadata: %{"request_metadata" => request["metadata"]}
      })

    {:ok, _} = ResponseCommit.commit_complete(previous, [])

    {:ok, _generating} =
      start_response_run(%{
        subject_uid: c.first.uid,
        conversation_id: model_run.conversation.id,
        previous_message_id: previous.id,
        metadata: %{"request_metadata" => request["metadata"]}
      })

    {:ok, workspace} = Ankole.Sessions.Workspaces.ensure(c.first.uid, input.session_id)

    active =
      struct(
        Ankole.Sessions.Run,
        Map.merge(model_run, %{
          event: input,
          delivered_event: input,
          epoch: workspace.epoch,
          workspace_id: workspace.id,
          saw_tool_results: true
        })
      )

    changed = observe(c.conversation.id, "background", c.second.uid, "Updated background")
    assert changed.id == background.id
    assert changed.seq == background.seq
    refute Repo.exists?(from s in Ankole.Signals.Signal, where: s.type == "input.revised")

    assert Ankole.Principals.WorkAccess.fields(active.event) ==
             Ankole.Principals.WorkAccess.fields(input)

    assert Repo.reload!(input).data == input.data

    assert {:ok, :ok} =
             Repo.transact(fn repo ->
               with :ok <- Ankole.Sessions.Fence.check_in_tx(repo, active),
                    :ok <- Ankole.Sessions.Queue.ensure_event_source_live_in_tx(repo, input, @now),
                    do: {:ok, :ok}
             end)

    next = ConversationContext.append(active, %{"metadata" => %{}, "input" => []})
    refute Ankole.JSON.encode!(next["input"]) =~ changed.text
    refute Ankole.JSON.encode!(next["input"]) =~ background.text
  end

  test "a high sequence watermark cannot claim that an omitted background message was read", c do
    input = signal(c, c.first, "conversation.message.addressed")
    background = observe(c.conversation.id, "omitted", c.second.uid, "Older omitted background")
    model_run = run(c, c.first, input)

    {:ok, _} =
      start_response_run(%{
        subject_uid: c.first.uid,
        conversation_id: model_run.conversation.id,
        metadata: %{
          "request_metadata" => %{
            "signal_id" => input.id,
            "conversation_read" => %{
              "id" => c.conversation.id,
              "max_seq" => background.seq,
              "message_ids" => [c.human_message.id]
            }
          }
        }
      })

    observe(c.conversation.id, "omitted", c.second.uid, "Updated omitted background")
    refute Repo.exists?(from s in Ankole.Signals.Signal, where: s.type == "input.revised")
  end

  test "permanently deleting one Agent keeps the shared room and the other Agent's history", c do
    first_signal = signal(c, c.first, "conversation.message.addressed")
    second_signal = signal(c, c.second, "conversation.message.addressed")
    first_reply = observe(c.conversation.id, "first", c.first.uid, "Agent A reply", first_signal)

    second_reply =
      observe(c.conversation.id, "second", c.second.uid, "Agent B reply", second_signal)

    first_run = run(c, c.first, first_signal)
    second_run = run(c, c.second, second_signal)
    {:ok, _} = Ankole.Sessions.Workspaces.ensure(c.first.uid, first_signal.session_id)

    {:ok, second_workspace} =
      Ankole.Sessions.Workspaces.ensure(c.second.uid, second_signal.session_id)

    native_id = Ecto.UUID.generate()

    assert {:ok, _} =
             Ankole.ConversationsFixtures.create(c.human.uid, %{
               conversation_id: native_id,
               agent_uid: c.first.uid,
               message_id: Ecto.UUID.generate(),
               text: "Private work"
             })

    assert {:ok, %{status: :disabled}} = Ankole.Principals.delete_agent(c.first.uid)
    assert {:ok, %{id: room_id}} = External.fetch_conversation(c.conversation.id)
    assert room_id == c.conversation.id
    assert Repo.get_by(Ankole.Conversations.Message, id: first_reply.id).text == first_reply.text
    assert {:ok, %{status: :disabled}} = Ankole.Principals.delete_agent(c.first.uid)

    assert {:ok, room} = External.fetch_conversation(c.conversation.id)
    assert room.id == c.conversation.id
    refute Repo.get_by(Ankole.Conversations.Conversation, id: native_id)
    assert Repo.get_by!(Ankole.Conversations.Message, id: first_reply.id).text == "Agent A reply"
    assert Repo.get_by!(Ankole.Conversations.Message, id: second_reply.id).text == "Agent B reply"

    assert %{message: %{id: id}, external_ref: %{provider_message_id: "first"}} =
             External.get_message(Repo, room.id, "first")

    assert id == first_reply.id

    assert [%{principal_uid: uid}] =
             Repo.all(from p in Participant, where: p.conversation_id == ^room.id)

    assert uid == c.second.uid
    refute Repo.get_by(Ankole.Sessions.SessionWorkspace, agent_uid: c.first.uid)

    refute Repo.exists?(
             from signal in Ankole.Signals.Signal, where: signal.agent_uid == ^c.first.uid
           )

    assert Repo.get!(Ankole.Sessions.SessionWorkspace, second_workspace.id)

    assert {:error, _} =
             AIGateway.get_conversation(c.first.uid, first_run.conversation.id,
               include_ended: true
             )

    assert {:ok, _} = AIGateway.get_conversation(c.second.uid, second_run.conversation.id)

    request = ConversationContext.append(second_run, %{"metadata" => %{}, "input" => []})
    assert Ankole.JSON.encode!(request["input"]) =~ "Agent A reply"
  end

  test "service event data cannot select another Human's Brain context", c do
    {:ok, signal} =
      Repo.transact(
        &Signals.accept_in_tx(&1, %{
          source: "https://service.test",
          id: Ecto.UUID.generate(),
          type: "service.changed",
          target: %{agent_uid: c.first.uid, session_id: "service:event"},
          authorization: Ankole.Principals.WorkAccess.service(),
          sender: c.human.uid,
          data: %{
            "author_uid" => c.human.uid,
            "entry" => %{"author" => %{"principal_uid" => c.human.uid}}
          }
        })
      )

    assert {:ok, context} =
             Ankole.Brain.RequestContext.build(c.first.uid, %{"signal_id" => signal.id})

    assert context.participant_uids == [c.first.uid]
    assert context.default_write_scope == {:ok, "principal:" <> c.first.uid}
    refute context.disclosure[:asker_uid]
  end

  defp observe_room(agent) do
    {:ok, conversation} =
      Repo.transact(
        &External.observe_conversation_in_tx(
          &1,
          %{agent_uid: agent.uid},
          %{
            provider_conversation_id: "lark:shared",
            external_kind: :im_group,
            title: "Shared room",
            reply_mode: :channel
          },
          @now
        )
      )

    conversation
  end

  defp observe(id, provider_id, uid, text, signal \\ nil) do
    {:ok, %{message: message}} =
      Repo.transact(
        &External.observe_in_tx(
          &1,
          id,
          %{
            provider_message_id: provider_id,
            author: %{"principal_uid" => uid},
            text: text,
            provider_time: @now,
            session_id: if(signal, do: signal.session_id),
            signal_id: if(signal, do: signal.id)
          },
          @now
        )
      )

    message
  end

  defp signal(c, agent, type) do
    data = %{
      "message_ids" => [c.human_message.id],
      "message_id" => c.human_message.id,
      "entries" => [%{"message_id" => c.human_message.id, "time" => DateTime.to_iso8601(@now)}],
      "ambient_batch" => %{
        "scene_fingerprint" => Context.ambient_scene_fingerprint(Repo, c.conversation.id),
        "expires_at" => DateTime.to_iso8601(DateTime.add(@now, 60, :second)),
        "as_of" => DateTime.to_iso8601(@now)
      }
    }

    {:ok, signal} =
      Repo.transact(
        &Signals.accept_in_tx(&1, %{
          producer: :kernel,
          source: "lark:shared",
          id: Ecto.UUID.generate(),
          type: type,
          target: %{agent_uid: agent.uid, conversation_id: c.conversation.id},
          authorization: Ankole.Principals.WorkAccess.service(),
          message_id: c.human_message.id,
          reply_route: %{binding_name: "room", conversation_id: c.conversation.id},
          data: data,
          time: @now
        })
      )

    signal
  end

  defp run(c, agent, signal) do
    {:ok, model} =
      Repo.transact(
        &AIGateway.ensure_conversation_in_tx(
          &1,
          agent.uid,
          Ankole.Sessions.Key.conversation(c.conversation.id)
        )
      )

    %{
      agent_uid: agent.uid,
      session_id: signal.session_id,
      signal_id: signal.id,
      steer_event_ids: [],
      conversation: model
    }
  end
end
