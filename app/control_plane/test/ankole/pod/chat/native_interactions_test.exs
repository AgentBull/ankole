defmodule Ankole.Pod.Chat.NativeInteractionsTest do
  use Ankole.DataCase, async: false
  import Ankole.AIGatewayCase, only: [start_response_run: 1]
  import Ankole.PrincipalsFixtures, only: [human_fixture: 1, actor_fixture: 1]
  alias Ankole.AIGateway.ResponseCommit
  alias Ankole.Conversations
  alias Ankole.Conversations.{Message, NativeRoom}
  alias Ankole.Conversations.Delivery.{Interactions, PreviewStates}
  alias Ankole.Sessions.{Admission, Model, Run, Tools}
  alias Ankole.Signals.Signal

  setup do
    alice = human_fixture(%{display_name: "Alice"}).principal
    bob = human_fixture(%{display_name: "Bob"}).principal
    agent = Ankole.SessionsCase.agent_fixture(%{owner_principal_uid: alice.uid}).principal
    for human <- [alice, bob], do: Ankole.ConversationsFixtures.grant_chat(human.uid, agent.uid)

    assert {:ok, _} =
             Ankole.AuthZ.create_permission_grant(%{
               principal_uid: alice.uid,
               resource_pattern: "agent:#{agent.uid}:tool:clarify",
               action: "invoke"
             })

    id = Ecto.UUID.generate()

    assert {:ok, _} =
             Conversations.create(actor_fixture(alice), %{
               conversation_id: id,
               agent_uid: agent.uid,
               message_id: Ecto.UUID.generate(),
               text: "Prepare a report."
             })

    assert {:ok, _} = NativeRoom.manage(actor_fixture(alice), id, %{add_uids: [bob.uid]})
    event = Repo.one!(from s in Signal, where: s.conversation_id == ^id)
    %{alice: alice, bob: bob, agent: agent, id: id, event: event}
  end

  test "a real native clarify tool commits a card, records the first answer, and resumes its Agent",
       ctx do
    card = clarify(ctx)
    interaction_id = card.rich_content["clarify"]["interaction_id"]
    assert card.delivery_key == "clarify:choose-report"
    assert card.author_display_name == ctx.agent.display_name
    assert card.rich_content["execution"]["steps"] |> Enum.any?(&(&1["tool"] == "clarify"))

    assert %{"state" => "pending"} =
             Interactions.native_interaction(card.signal_id, interaction_id)

    assert {:ok, _detail} =
             Conversations.answer_interaction(actor_fixture(ctx.bob), ctx.id, interaction_id, %{
               choice_id: "choice-2"
             })

    assert %{
             "state" => "answered",
             "answered_by_uid" => uid,
             "answered_by_name" => "Bob",
             "choice_id" => "choice-2"
           } =
             Interactions.native_interaction(card.signal_id, interaction_id)

    assert uid == ctx.bob.uid

    assert [%Signal{agent_uid: agent_uid, human_uid: ^uid} = reply] =
             Repo.all(
               from s in Signal, where: s.conversation_id == ^ctx.id and s.id != ^ctx.event.id
             )

    assert agent_uid == ctx.agent.uid
    assert reply.data["text"] == "Draft only"

    assert {:error, :interaction_not_pending} =
             Repo.transact_top_level(fn ->
               Interactions.accept_native_in_tx(
                 actor_fixture(ctx.alice),
                 ctx.id,
                 interaction_id,
                 %{choice_id: "choice-1"}
               )
             end)

    assert Repo.aggregate(
             from(m in Message, where: m.conversation_id == ^ctx.id and m.text == "Draft only"),
             :count
           ) == 1
  end

  test "a referenced free-text answer targets the asking Agent when intervention is off", ctx do
    card = clarify(ctx)
    interaction_id = card.rich_content["clarify"]["interaction_id"]
    actor = actor_fixture(ctx.alice)

    assert {:ok, page} = Ankole.Pod.Pages.create(actor, %{title: "Report evidence"})

    assert {:ok, _} =
             Conversations.manage_participants(actor, ctx.id, %{
               agent_uid: ctx.agent.uid,
               may_intervene: false
             })

    links = [
      %{"kind" => "page", "id" => page.id},
      %{"kind" => "message", "id" => card.id, "quote" => "  Use this context.\n"}
    ]

    assert {:ok, result} =
             Repo.transact_top_level(fn ->
               Interactions.accept_native_in_tx(actor, ctx.id, interaction_id, %{
                 answer_text: "Use these references.",
                 links: links
               })
             end)

    assert [reply] = result.events
    assert reply.agent_uid == ctx.agent.uid
    assert reply.data["text"] == "Use these references."
    assert Conversations.get_message!(reply.message_id).links == links

    assert %{"state" => "answered", "answer_text" => "Use these references."} =
             Interactions.native_interaction(card.signal_id, interaction_id)
  end

  test "prose precedes Clarify and owns the execution summary once", ctx do
    card = clarify(ctx, "I reviewed the available destinations.")
    assert {:ok, detail} = Conversations.get(actor_fixture(ctx.alice), ctx.id)
    outputs = Enum.filter(detail.messages, &(&1.author_type == :agent))
    assert [prose, question] = outputs
    assert prose.text == "I reviewed the available destinations."
    assert question.id == card.id
    assert prose.seq < question.seq
    assert is_map(prose.rich_content["execution"])
    refute Map.has_key?(question.rich_content, "execution")
    projection = Ankole.Pod.Chat.Presentation.detail(detail)
    assert [%{"messageID" => id}] = projection.pendingInteractions
    assert id == question.id
  end

  test "an attachment-only answer keeps its uploaded bytes, Human mention, and asking Agent",
       ctx do
    card = clarify(ctx)
    interaction_id = card.rich_content["clarify"]["interaction_id"]
    actor = actor_fixture(ctx.bob)
    other = Ankole.SessionsCase.agent_fixture(%{owner_principal_uid: ctx.alice.uid}).principal

    for human <- [ctx.alice, ctx.bob],
        do: Ankole.ConversationsFixtures.grant_chat(human.uid, other.uid)

    assert {:ok, _} =
             NativeRoom.manage(actor_fixture(ctx.alice), ctx.id, %{add_uids: [other.uid]})

    assert {:ok, _} =
             NativeRoom.manage(actor_fixture(ctx.alice), ctx.id, %{
               agent_uid: other.uid,
               may_intervene: true
             })

    assert {:ok, _} =
             NativeRoom.manage(actor_fixture(ctx.alice), ctx.id, %{
               agent_uid: ctx.agent.uid,
               may_intervene: false
             })

    bytes = "The report specification attached to the answer."
    local = Ankole.Files.temp_path()
    File.write!(local, bytes)
    on_exit(fn -> File.rm(local) end)

    assert {:ok, upload} =
             Ankole.Conversations.Attachments.Native.upload(
               actor,
               Ecto.UUID.generate(),
               "report-specification.txt",
               {:file, local},
               "text/plain"
             )

    input =
      Ash.ActionInput.for_action(
        Ankole.Pod.Chat.Browser,
        :answer_interaction,
        %{
          id: ctx.id,
          interaction_id: interaction_id,
          text: "",
          attachments: [upload.receipt],
          mentions: [%{type: :human, uid: ctx.alice.uid}, %{type: :agent, uid: other.uid}]
        },
        tenant: Repo.tenant_id!()
      )

    assert {:ok, _detail} = Ankole.Ash.run_action_authorized(input, actor)

    assert [%Signal{agent_uid: agent_uid, human_uid: human_uid} = reply] =
             Repo.all(
               from s in Signal, where: s.conversation_id == ^ctx.id and s.id != ^ctx.event.id
             )

    assert agent_uid == ctx.agent.uid
    assert human_uid == ctx.bob.uid
    answer = Conversations.get_message!(reply.message_id)
    assert answer.author_uid == ctx.bob.uid
    assert is_nil(answer.text)
    assert answer.mentions == [%{"type" => "human", "uid" => ctx.alice.uid}]
    assert [attachment] = answer.attachments
    assert attachment["name"] == "report-specification.txt"
    assert attachment["path"] =~ "chats/#{ctx.id}/inbox/#{answer.id}/"
    assert {:ok, ^bytes} = Ankole.Files.read_content(attachment["blob_ref"])
    assert reply.data["entry"] == %{"text" => nil, "attachments" => [attachment]}

    assert %{"state" => "answered", "answer_text" => "", "answered_by_uid" => answered_by} =
             Interactions.native_interaction(card.signal_id, interaction_id)

    assert answered_by == ctx.bob.uid
  end

  test "a native answer preserves indentation and text longer than 1000 characters", ctx do
    card = clarify(ctx)
    interaction_id = card.rich_content["clarify"]["interaction_id"]

    text =
      "\n  Report specification:\n" <> String.duplicate("    Preserve this line.\n", 60) <> "\n"

    assert String.length(text) > 1_000

    input =
      Ash.ActionInput.for_action(
        Ankole.Pod.Chat.Browser,
        :answer_interaction,
        %{id: ctx.id, interaction_id: interaction_id, text: text},
        tenant: Repo.tenant_id!()
      )

    assert {:ok, _detail} = Ankole.Ash.run_action_authorized(input, actor_fixture(ctx.bob))

    assert [reply] =
             Repo.all(
               from s in Signal, where: s.conversation_id == ^ctx.id and s.id != ^ctx.event.id
             )

    assert reply.agent_uid == ctx.agent.uid
    assert reply.data["text"] == text
    assert Conversations.get_message!(reply.message_id).text == text

    assert %{"state" => "answered", "answer_text" => ^text} =
             Interactions.native_interaction(card.signal_id, interaction_id)
  end

  test "ordinary new input supersedes the old native card", ctx do
    card = clarify(ctx)

    assert {:ok, _} =
             Conversations.post(actor_fixture(ctx.alice), ctx.id, %{
               message_id: Ecto.UUID.generate(),
               text: "Use the current project instead."
             })

    assert %{"state" => "superseded"} =
             Interactions.native_interaction(
               card.signal_id,
               card.rich_content["clarify"]["interaction_id"]
             )
  end

  test "a pending decision remains visible and actionable outside the latest history window",
       ctx do
    card = clarify(ctx)
    actor = actor_fixture(ctx.alice)
    room = Conversations.get_conversation!(ctx.id)
    now = DateTime.utc_now(:microsecond)

    rows =
      for seq <- (room.sequence_high_water + 1)..(room.sequence_high_water + 501) do
        %{
          id: Ankole.Ecto.UUIDv7.autogenerate(),
          tenant_id: Repo.tenant_id!(),
          conversation_id: ctx.id,
          seq: seq,
          origin: :native,
          author_type: :human,
          author_uid: ctx.bob.uid,
          author_display_name: ctx.bob.display_name,
          kind: :message,
          text: "Later room discussion #{seq}",
          created_at: now
        }
      end

    Repo.insert_all(Message, rows)

    Repo.update_all(where(Ankole.Conversations.Conversation, id: ^ctx.id),
      set: [sequence_high_water: room.sequence_high_water + 501]
    )

    assert {:ok, detail} = Conversations.get(actor, ctx.id)
    projection = Ankole.Pod.Chat.Presentation.detail(detail)
    refute Enum.any?(projection.messages, &(&1.id == card.id))
    assert [decision] = projection.pendingInteractions
    assert decision["messageID"] == card.id
    assert decision["agentUID"] == ctx.agent.uid
    assert decision["question"] == "Where should the report go?"
    assert Enum.map(decision["choices"], & &1["label"]) == ["Publish", "Draft only"]

    assert {:ok, _} =
             Repo.transact_top_level(fn ->
               Interactions.accept_native_in_tx(actor, ctx.id, decision["interaction_id"], %{
                 choice_id: "choice-2"
               })
             end)

    assert {:ok, answered} = Conversations.get(actor, ctx.id)
    assert Ankole.Pod.Chat.Presentation.detail(answered).pendingInteractions == []
  end

  test "invalid answers and revoked room access do not consume a pending card", ctx do
    card = clarify(ctx)
    id = card.rich_content["clarify"]["interaction_id"]

    assert {:error, :invalid_reply_interaction} =
             Repo.transact_top_level(fn ->
               Interactions.accept_native_in_tx(actor_fixture(ctx.bob), ctx.id, id, %{
                 choice_id: "missing"
               })
             end)

    assert {:ok, _} =
             NativeRoom.manage(actor_fixture(ctx.alice), ctx.id, %{remove_uids: [ctx.bob.uid]})

    assert {:error, :conversation_not_found} =
             Repo.transact_top_level(fn ->
               Interactions.accept_native_in_tx(actor_fixture(ctx.bob), ctx.id, id, %{
                 answer_text: "Late answer"
               })
             end)

    assert %{"state" => "pending"} = Interactions.native_interaction(card.signal_id, id)
  end

  test "Pod RPC reads use the speaking Human intersection even with a privileged room member",
       ctx do
    alias Ankole.Pod.{Database, Pages, RPCBroker}
    alias Ankole.RuntimeFabric.V1.PodRequest
    alias Ankole.Sessions.RunRef
    alice = actor_fixture(ctx.alice)

    assert {:ok, document} =
             Pages.create(alice, %{title: "Private report", private_owner_uid: ctx.alice.uid})

    assert {:ok, database} =
             Pages.create(alice, %{
               title: "Private budget",
               type: "database",
               private_owner_uid: ctx.alice.uid
             })

    assert {:ok, table} = Database.create_table(alice, database.id, %{name: "Budget"})

    assert {:ok, %{records: [_]}} =
             Database.write_records(alice, table.id, %{creates: [%{data: %{}}]})

    for page <- [document, database] do
      assert {:ok, _} =
               Ankole.Pod.PagesFixtures.set_sharing(ctx.alice.uid, page.id, %{
                 grants: [%{principal_uid: ctx.agent.uid, role: "view"}]
               })

      assert {:ok, _} = Pages.authorize(actor_fixture(ctx.agent), page.id, "page_view")
      assert {:error, :forbidden} = Pages.authorize(actor_fixture(ctx.bob), page.id, "page_view")
    end

    rpc_context = %{
      worker_id: ctx.agent.uid,
      route: "native-read-intersection",
      request_id: "read-private"
    }

    alice_ref = %RunRef{
      agent_uid: ctx.agent.uid,
      session_id: ctx.event.session_id,
      signal_id: ctx.event.id
    }

    query = %PodRequest{
      operation: "database.query",
      params_json: Ankole.JSON.encode!(%{id: table.id})
    }

    assert {:ok, %{"result" => %{"records" => [_]}}} =
             RPCBroker.handle_read(alice_ref, query, rpc_context)

    assert {:ok, _} =
             Conversations.post(actor_fixture(ctx.bob), ctx.id, %{
               message_id: Ecto.UUID.generate(),
               text: "Read the private budget.",
               target_agent_uid: ctx.agent.uid
             })

    event =
      Repo.one!(
        from s in Signal, where: s.conversation_id == ^ctx.id and s.human_uid == ^ctx.bob.uid
      )

    bob_ref = %RunRef{agent_uid: ctx.agent.uid, session_id: event.session_id, signal_id: event.id}

    read = %PodRequest{
      operation: "pages.read",
      params_json: Ankole.JSON.encode!(%{id: document.id, xml_home_relative_path: "private.xml"})
    }

    assert {:error, %{"code" => "forbidden"}} = RPCBroker.handle_read(bob_ref, read, rpc_context)
    assert {:error, %{"code" => "forbidden"}} = RPCBroker.handle_read(bob_ref, query, rpc_context)

    assert {:ok, _} =
             Ankole.Pod.PagesFixtures.set_sharing(ctx.alice.uid, database.id, %{
               grants: [
                 %{principal_uid: ctx.agent.uid, role: "view"},
                 %{principal_uid: ctx.bob.uid, role: "view"}
               ]
             })

    assert {:ok, %{"result" => %{"records" => [_]}}} =
             RPCBroker.handle_read(bob_ref, query, rpc_context)
  end

  defp clarify(ctx, text \\ nil) do
    assert {:ok, run} =
             Admission.admit(
               %{agent_uid: ctx.agent.uid, session_id: ctx.event.session_id},
               ctx.event
             )

    assert {:ok, {:preparing, run}} = Model.prepare(run)

    call = %{
      "type" => "function_call",
      "name" => "clarify",
      "call_id" => "choose-report",
      "arguments" =>
        Ankole.JSON.encode!(%{
          "question" => "Where should the report go?",
          "choices" => [%{"label" => "Publish"}, %{"label" => "Draft only"}]
        })
    }

    assert {:ok, response} =
             start_response_run(%{
               subject_uid: run.agent_uid,
               conversation_id: run.conversation.id,
               round_state: run,
               metadata: %{"request_metadata" => Run.metadata(run)}
             })

    assert {:ok, response} = ResponseCommit.commit_complete(response, [call])

    run = %{
      run
      | model_response: response,
        calls: [call],
        round_calls: [call],
        anchor: response.id
    }

    assert {:ok, tool, args} = Tools.prepare(run, call)
    result = Tools.execute(run, call, tool, args)
    refute result.is_error
    assert {:ok, _journal} = Run.record_round(%{run | results: %{call["call_id"] => result}})
    assert {:ok, {_state, run}} = Run.restore(run)

    run =
      if text do
        assert {:ok, response} =
                 start_response_run(%{
                   subject_uid: run.agent_uid,
                   conversation_id: run.conversation.id,
                   round_state: run,
                   metadata: %{"request_metadata" => Run.metadata(run)}
                 })

        assert {:ok, _response} =
                 ResponseCommit.commit_complete(response, [
                   %{"type" => "output_text", "text" => text}
                 ])

        assert {:ok, {_state, run}} = Run.restore(run)
        run
      else
        run
      end

    assert {:ok, finalized} = Run.finalize(run)
    card = List.last(finalized.posted.messages)

    assert PreviewStates.get(ctx.event).checkpoint["interactions"]["clarify:choose-report"][
             "state"
           ] == "pending"

    card
  end
end
