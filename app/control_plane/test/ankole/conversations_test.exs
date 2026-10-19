defmodule Ankole.ConversationsTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.Conversations
  alias Ankole.Conversations.Conversation
  alias Ankole.Conversations.Message
  alias Ankole.Conversations.Participant
  alias Ankole.Signals.Signal
  alias Ankole.Signals.Binding
  alias Ankole.Conversations.ExternalMessageRef
  alias Ankole.Conversations.Delivery.Intent

  setup do
    %{principal: human} = human_fixture()
    %{principal: agent} = agent_fixture(%{owner_principal_uid: human.uid})
    %{human: human, agent: agent}
  end

  test "creates the shared space, first message, authorized signal, and model conversation atomically",
       %{
         human: human,
         agent: agent
       } do
    attrs = attrs(agent)
    assert {:ok, detail} = in_tx(fn -> Ankole.ConversationsFixtures.create(human.uid, attrs) end)
    assert detail.conversation.id == attrs.conversation_id
    assert detail.conversation.kind == :native
    assert detail.conversation.created_by == human.uid
    assert detail.conversation.title == attrs.text
    assert [%Message{seq: 1, author_type: :human, origin: :native} = message] = detail.messages
    assert message.id == attrs.message_id
    assert message.text == attrs.text
    assert message.author_uid == human.uid
    assert is_nil(message.signal_id)
    assert detail.agent.uid == agent.uid

    assert Ankole.Sessions.status(%{agent_uid: agent.uid, session_id: detail.session_id}) ==
             %{state: :queued, retry_at: nil}

    assert is_binary(detail.model_conversation_id)

    assert [%{role: :owner, principal_uid: owner}, %{role: :agent, principal_uid: respondent}] =
             Repo.all(from p in Participant, order_by: [desc: p.role])

    assert owner == human.uid
    assert respondent == agent.uid

    event = Repo.one!(Signal)
    assert event.type == "conversation.message.addressed"
    assert event.session_id == "conversation:#{attrs.conversation_id}"
    assert event.source == event.session_id
    assert is_nil(event.reply_binding_name)
    assert event.message_id == attrs.message_id
    assert event.source_event_id == attrs.message_id
    assert event.sender_key == human.uid
    assert event.authorization_kind == "human"
    assert event.human_uid == human.uid
    assert event.human_access_version == human.access_version
    assert event.subject == attrs.conversation_id

    assert event.data == %{
             "conversation_id" => attrs.conversation_id,
             "message_id" => attrs.message_id,
             "message_ids" => [attrs.message_id],
             "author_uid" => human.uid,
             "model_profile" => "primary",
             "text" => attrs.text
           }

    assert_enqueued(
      worker: Ankole.Sessions.Jobs.EnsureDriver,
      args: %{agent_uid: agent.uid, session_id: event.session_id, tenant_id: Repo.tenant_id!()}
    )

    assert_no_adapter_rows()
  end

  test "retries preserve one fact, while changed IDs or content conflict", %{
    human: human,
    agent: agent
  } do
    attrs = attrs(agent)
    assert {:ok, first} = in_tx(fn -> Ankole.ConversationsFixtures.create(human.uid, attrs) end)
    assert {:ok, retried} = in_tx(fn -> Ankole.ConversationsFixtures.create(human.uid, attrs) end)
    assert retried.messages == first.messages
    assert Repo.aggregate(Message, :count) == 1
    assert Repo.aggregate(Signal, :count) == 1

    assert {:error, :conversation_conflict} =
             in_tx(fn ->
               Ankole.ConversationsFixtures.create(human.uid, %{
                 attrs
                 | text: "Different first request"
               })
             end)

    assert {:error, :conversation_conflict} =
             in_tx(fn ->
               Ankole.ConversationsFixtures.create(human.uid, %{
                 attrs
                 | message_id: Ecto.UUID.generate()
               })
             end)

    %{principal: other_agent} = agent_fixture(%{owner_principal_uid: human.uid})

    assert {:error, :conversation_conflict} =
             in_tx(fn ->
               Ankole.ConversationsFixtures.create(human.uid, %{
                 attrs
                 | agent_uid: other_agent.uid
               })
             end)

    followup = %{message_id: Ecto.UUID.generate(), text: "  Keep this exact text.\n"}

    assert {:ok, posted} =
             in_tx(fn ->
               Ankole.ConversationsFixtures.post(human.uid, attrs.conversation_id, followup)
             end)

    assert Enum.map(posted.messages, & &1.seq) == [1, 2]
    assert List.last(posted.messages).text == followup.text

    assert {:ok, retried} =
             in_tx(fn ->
               Ankole.ConversationsFixtures.post(human.uid, attrs.conversation_id, followup)
             end)

    assert retried.messages == posted.messages

    assert {:error, :conversation_conflict} =
             in_tx(fn ->
               Ankole.ConversationsFixtures.post(human.uid, attrs.conversation_id, %{
                 followup
                 | text: "Changed"
               })
             end)

    assert Repo.aggregate(Message, :count) == 2
    assert Repo.aggregate(Signal, :count) == 2

    assert Enum.map(
             Repo.all(from e in Signal, order_by: e.queue_sequence),
             & &1.queue_sequence
           ) == [1, 2]

    assert_no_adapter_rows()
  end

  test "another Human or tenant cannot read or write the conversation", %{
    human: human,
    agent: agent
  } do
    attrs = attrs(agent)
    assert {:ok, _} = in_tx(fn -> Ankole.ConversationsFixtures.create(human.uid, attrs) end)
    %{principal: stranger} = human_fixture()
    assert Conversations.list(stranger.uid) == []

    assert {:error, :conversation_not_found} =
             Conversations.get(stranger.uid, attrs.conversation_id)

    assert {:error, :conversation_not_found} =
             Ankole.ConversationsFixtures.post(stranger.uid, attrs.conversation_id, %{
               message_id: Ecto.UUID.generate(),
               text: "Read someone else's data"
             })

    other_tenant = create_tenant()

    Repo.with_tenant(other_tenant.id, fn ->
      assert Conversations.list(human.uid) == []

      assert {:error, :conversation_not_found} =
               Conversations.get(human.uid, attrs.conversation_id)

      assert {:error, :conversation_not_found} =
               Ankole.ConversationsFixtures.post(human.uid, attrs.conversation_id, %{
                 message_id: Ecto.UUID.generate(),
                 text: "Cross tenant write"
               })

      assert Conversations.agents() == []
    end)

    assert [%{conversation: %{id: id}, agent: %{uid: uid}}] = Conversations.list(human.uid)
    assert id == attrs.conversation_id
    assert uid == agent.uid
  end

  test "a disabled Agent keeps read-only history and permanent deletion removes the whole space",
       %{
         human: human,
         agent: agent
       } do
    attrs = attrs(agent)
    assert {:ok, _} = in_tx(fn -> Ankole.ConversationsFixtures.create(human.uid, attrs) end)

    assert {:ok, _} =
             in_tx(fn ->
               event = Repo.one!(Signal)

               with {:ok, _} <-
                      Ankole.ConversationsFixtures.post_statement_in_tx(Repo, event, "Answer"),
                    {:ok, event} <-
                      Ankole.Sessions.Queue.mark_event_completed_in_tx(
                        Repo,
                        event,
                        DateTime.utc_now(:microsecond)
                      ),
                    do: {:ok, event}
             end)

    followup = %{message_id: Ecto.UUID.generate(), text: "Follow up"}

    assert {:ok, _} =
             in_tx(fn ->
               Ankole.ConversationsFixtures.post(human.uid, attrs.conversation_id, followup)
             end)

    assert {:ok, _} =
             in_tx(fn ->
               event = Repo.get_by!(Signal, source_event_id: followup.message_id)

               with {:ok, _} <-
                      Ankole.ConversationsFixtures.post_statement_in_tx(
                        Repo,
                        event,
                        "Work stopped",
                        kind: :notice
                      ),
                    {:ok, event} <-
                      Ankole.Sessions.Queue.mark_event_completed_in_tx(
                        Repo,
                        event,
                        DateTime.utc_now(:microsecond)
                      ),
                    do: {:ok, event}
             end)

    assert {:ok, %{messages: [_, _, _, _]} = detail} =
             Conversations.get(human.uid, attrs.conversation_id)

    assert Ankole.Sessions.status(%{agent_uid: agent.uid, session_id: detail.session_id}).state ==
             :idle

    :ok = Conversations.subscribe(attrs.conversation_id)
    assert {:ok, %{status: :disabled}} = Ankole.Principals.delete_agent(agent.uid)
    assert_receive {:conversation_event, id, :status}
    assert id == attrs.conversation_id
    assert Conversations.agents() == []

    assert {:ok, %{agent: %{status: :disabled}, messages: [_, _, _, _]}} =
             Conversations.get(human.uid, attrs.conversation_id)

    assert {:error, :agent_unavailable} =
             in_tx(fn ->
               Ankole.ConversationsFixtures.post(human.uid, attrs.conversation_id, %{
                 message_id: Ecto.UUID.generate(),
                 text: "New work"
               })
             end)

    assert {:error, :agent_unavailable} =
             in_tx(fn -> Ankole.ConversationsFixtures.create(human.uid, attrs(agent)) end)

    assert {:ok, %{status: :active}} = Ankole.Principals.enable_agent(agent.uid)
    assert_receive {:conversation_event, ^id, :status}
    assert {:ok, %{agent: %{status: :active}}} = Conversations.get(human.uid, id)
    assert {:ok, %{status: :disabled}} = Ankole.Principals.delete_agent(agent.uid)
    assert_receive {:conversation_event, ^id, :status}
    assert {:ok, %{status: :disabled}} = Ankole.Principals.delete_agent(agent.uid)
    assert_receive {:conversation_event, ^id, :status}
    assert {:error, :conversation_not_found} = Conversations.get(human.uid, attrs.conversation_id)
    assert Repo.aggregate(Conversation, :count) == 0
    assert Repo.aggregate(Participant, :count) == 0
    assert Repo.aggregate(Message, :count) == 0
    assert Repo.aggregate(Signal, :count) == 0
    assert_no_adapter_rows()
  end

  test "Agent lifecycle publishes every affected native space and remains quiet on rollback", %{
    human: human,
    agent: agent
  } do
    first = attrs(agent)
    second = attrs(agent)

    for attrs <- [first, second] do
      assert {:ok, _} = in_tx(fn -> Ankole.ConversationsFixtures.create(human.uid, attrs) end)
      :ok = Conversations.subscribe(attrs.conversation_id)
    end

    assert {:error, :rollback} =
             Repo.transact(fn _ ->
               assert {:ok, %{status: :disabled}} = Ankole.Principals.delete_agent(agent.uid)
               {:error, :rollback}
             end)

    refute_receive {:conversation_event, _, :status}

    assert {:ok, %{agent: %{status: :active}}} =
             Conversations.get(human.uid, first.conversation_id)

    assert {:ok, %{status: :disabled}} = Ankole.Principals.delete_agent(agent.uid)
    first_id = first.conversation_id
    second_id = second.conversation_id
    assert_receive {:conversation_event, ^first_id, :status}
    assert_receive {:conversation_event, ^second_id, :status}

    assert {:error, :rollback} =
             Repo.transact(fn _ ->
               assert {:ok, %{status: :active}} = Ankole.Principals.enable_agent(agent.uid)
               {:error, :rollback}
             end)

    refute_receive {:conversation_event, _, :status}

    assert {:error, :rollback} =
             Repo.transact(fn _ ->
               assert {:ok, %{status: :disabled}} = Ankole.Principals.delete_agent(agent.uid)
               {:error, :rollback}
             end)

    refute_receive {:conversation_event, _, :status}
    assert {:ok, %{agent: %{status: :disabled}}} = Conversations.get(human.uid, first_id)
    assert {:ok, %{agent: %{status: :disabled}}} = Conversations.get(human.uid, second_id)

    assert {:ok, %{status: :disabled}} = Ankole.Principals.delete_agent(agent.uid)
    assert_receive {:conversation_event, ^first_id, :status}
    assert_receive {:conversation_event, ^second_id, :status}
    assert Conversations.list(human.uid) == []
  end

  test "bad identifiers and blank or malformed text leave no accepted facts", %{
    human: human,
    agent: agent
  } do
    attrs = attrs(agent)

    assert {:error, :invalid_id} =
             Ankole.ConversationsFixtures.create(human.uid, %{
               attrs
               | conversation_id: "not-a-uuid"
             })

    assert {:error, :invalid_id} =
             Ankole.ConversationsFixtures.create(human.uid, %{attrs | message_id: "not-a-uuid"})

    for text <- [nil, " \n\t", <<255>>, <<0>>, "a" <> <<0>> <> "b", 23] do
      assert {:error, :invalid_text} =
               Ankole.ConversationsFixtures.create(human.uid, %{attrs | text: text})
    end

    assert {:error, :invalid_request} = Ankole.ConversationsFixtures.create(human.uid, nil)
    assert Repo.aggregate(Conversation, :count) == 0
    assert Repo.aggregate(Message, :count) == 0
    assert Repo.aggregate(Signal, :count) == 0
  end

  test "posting NUL text returns invalid_text without changing messages or accepted work", %{
    human: human,
    agent: agent
  } do
    attrs = attrs(agent)

    assert {:ok, original} =
             in_tx(fn -> Ankole.ConversationsFixtures.create(human.uid, attrs) end)

    :ok = Conversations.subscribe(attrs.conversation_id)

    for text <- [<<0>>, "a" <> <<0>> <> "b"] do
      assert {:error, :invalid_text} =
               Ankole.ConversationsFixtures.post(human.uid, attrs.conversation_id, %{
                 message_id: Ecto.UUID.generate(),
                 text: text
               })
    end

    refute_receive {:conversation_event, _, _}
    assert {:ok, unchanged} = Conversations.get(human.uid, attrs.conversation_id)
    assert unchanged == original
    assert Repo.aggregate(Message, :count) == 1
    assert Repo.aggregate(Signal, :count) == 1
  end

  @tag sandbox: false
  test "concurrent submissions and retries keep one increasing sequence", %{
    human: human,
    agent: agent,
    tenant: tenant
  } do
    on_exit(fn ->
      Repo.with_tenant(tenant.id, fn ->
        delete_agent_fixture_rows(agent.uid)

        Repo.delete_all(
          from j in Oban.Job, where: fragment("?->>'tenant_id' = ?", j.args, ^tenant.id)
        )

        # Space initialization owns rows beyond this test's Agent fixture.
        Repo.delete_all(Ankole.AuthZ.Grant)
        Repo.delete_all(Ankole.AuthZ.Group)
        Repo.delete!(tenant)
      end)
    end)

    attrs = attrs(agent)
    assert {:ok, _} = in_tx(fn -> Ankole.ConversationsFixtures.create(human.uid, attrs) end)
    submissions = for n <- 1..12, do: %{message_id: Ecto.UUID.generate(), text: "Message #{n}"}

    tasks =
      Enum.map(submissions ++ submissions, fn submission ->
        Task.async(
          Repo.bind_tenant(fn ->
            in_tx(fn ->
              Ankole.ConversationsFixtures.post(human.uid, attrs.conversation_id, submission)
            end)
          end)
        )
      end)

    Enum.each(tasks, fn task -> assert {:ok, _} = Task.await(task, 15_000) end)

    assert {:ok, detail} = Conversations.get(human.uid, attrs.conversation_id)
    assert Enum.map(detail.messages, & &1.seq) == Enum.to_list(1..13)
    assert Enum.map(detail.messages, & &1.id) |> Enum.uniq() |> length() == 13
    assert Repo.aggregate(Signal, :count) == 13
    assert_no_adapter_rows()
  end

  test "rollback removes message, signal, model conversation, and wakeup without publishing", %{
    human: human,
    agent: agent
  } do
    attrs = attrs(agent)
    :ok = Conversations.subscribe(attrs.conversation_id)

    assert {:error, :rollback} =
             Repo.transact(fn repo ->
               assert {:ok, %{publications: [_, _]}} =
                        Conversations.create_in_tx(repo, human.uid, attrs)

               refute_received {:conversation_event, _, _}
               {:error, :rollback}
             end)

    refute_receive {:conversation_event, _, _}
    assert Repo.aggregate(Conversation, :count) == 0
    assert Repo.aggregate(Message, :count) == 0
    assert Repo.aggregate(Signal, :count) == 0
    assert Repo.aggregate(Ankole.AIGateway.Schemas.Conversation, :count) == 0

    refute_enqueued(
      worker: Ankole.Sessions.Jobs.EnsureDriver,
      args: %{tenant_id: Repo.tenant_id!()}
    )

    assert :undefined =
             Ankole.Sessions.driver_pid(%{
               agent_uid: agent.uid,
               session_id: Ankole.Sessions.Key.conversation(attrs.conversation_id)
             })
  end

  test "the Agent statement preserves provenance and repeats once; silent output writes nothing",
       %{
         human: human,
         agent: agent
       } do
    attrs = attrs(agent)
    assert {:ok, _} = in_tx(fn -> Ankole.ConversationsFixtures.create(human.uid, attrs) end)
    event = Repo.one!(Signal)

    assert {:ok, %{messages: []}} =
             in_tx(fn -> Ankole.ConversationsFixtures.post_statement_in_tx(Repo, event, nil) end)

    assert {:ok, %{messages: [message]}} =
             in_tx(fn ->
               Ankole.ConversationsFixtures.post_statement_in_tx(Repo, event, "Answer")
             end)

    assert message.seq == 2
    assert message.author_type == :agent
    assert message.author_uid == agent.uid
    assert message.signal_id == event.id
    assert message.session_id == event.session_id
    assert message.reply_to_message_id == attrs.message_id

    assert {:ok, %{messages: [^message]}} =
             in_tx(fn ->
               Ankole.ConversationsFixtures.post_statement_in_tx(Repo, event, "Answer")
             end)

    assert {:error, :conversation_conflict} =
             in_tx(fn ->
               Ankole.ConversationsFixtures.post_statement_in_tx(Repo, event, "Changed answer")
             end)

    assert Repo.aggregate(Message, :count) == 2
    assert_no_adapter_rows()
  end

  test "database constraints reject missing Agent provenance and an author from another tenant",
       %{
         human: human,
         agent: agent
       } do
    attrs = attrs(agent)
    assert {:ok, _} = in_tx(fn -> Ankole.ConversationsFixtures.create(human.uid, attrs) end)
    event = Repo.one!(Signal)

    message_attrs = %{
      id: Ecto.UUID.generate(),
      conversation_id: attrs.conversation_id,
      seq: 2,
      author_type: :agent,
      author_uid: agent.uid,
      kind: :message,
      origin: :native,
      text: "A visible answer",
      signal_id: event.id,
      created_at: DateTime.utc_now(:microsecond)
    }

    assert {:error, changeset} =
             %Message{}
             |> Message.changeset(message_attrs)
             |> Repo.insert(mode: :savepoint)

    assert "is invalid" in errors_on(changeset).signal_id

    other_tenant = create_tenant()
    %{principal: foreign_human} = Repo.with_tenant(other_tenant.id, fn -> human_fixture() end)

    message_attrs = %{
      message_attrs
      | author_type: :human,
        author_uid: foreign_human.uid,
        signal_id: nil
    }

    assert {:error, changeset} =
             %Message{}
             |> Message.changeset(message_attrs)
             |> Repo.insert(mode: :savepoint)

    assert "does not exist" in errors_on(changeset).author_uid
    assert Repo.aggregate(Message, :count) == 1
  end

  test "PubSub uses the tenant as part of the audience", %{human: human, agent: agent} do
    attrs = attrs(agent)
    assert {:ok, _} = in_tx(fn -> Ankole.ConversationsFixtures.create(human.uid, attrs) end)
    event = Repo.one!(Signal)
    :ok = Conversations.subscribe(attrs.conversation_id)
    other_tenant = create_tenant()
    Repo.with_tenant(other_tenant.id, fn -> Conversations.publish_message(event) end)
    refute_receive {:conversation_event, _, _}
    assert :ok = Conversations.publish_message(event)
    assert_receive {:conversation_event, id, :message}
    assert id == attrs.conversation_id
    assert :ok = Conversations.publish_status(event)
    assert_receive {:conversation_event, ^id, :status}
  end

  test "publishing entry points reject nested transactions before writing", %{
    human: human,
    agent: agent
  } do
    request = attrs(agent)

    for operation <- [
          fn -> Ankole.Conversations.create(human.uid, request) end,
          fn ->
            Ankole.Conversations.post(human.uid, request.conversation_id, %{
              message_id: request.message_id,
              text: "hello"
            })
          end,
          fn ->
            Ankole.Conversations.publish_statement(%Message{
              conversation_id: request.conversation_id
            })
          end
        ] do
      assert_raise ArgumentError, ~r/publish after commit/, fn ->
        Repo.transact(fn _ -> operation.() end)
      end
    end

    assert Repo.aggregate(Message, :count) == 0
  end

  test "a transaction owner publishes only its committed facts", %{human: human, agent: agent} do
    request = attrs(agent)
    :ok = Conversations.subscribe(request.conversation_id)

    assert {:error, :aborted} =
             Repo.transact(fn repo ->
               assert {:ok, %{publications: [_, _]}} =
                        Conversations.create_in_tx(repo, human.uid, request)

               refute_received {:conversation_event, _, _}
               repo.rollback(:aborted)
             end)

    refute_received {:conversation_event, _, _}
    assert Repo.aggregate(Message, :count) == 0

    assert {:ok, %{publications: publications}} =
             Repo.transact(fn repo ->
               Conversations.create_in_tx(repo, human.uid, request)
             end)

    refute_received {:conversation_event, _, _}
    assert :ok = Conversations.publish_committed(publications)
    id = request.conversation_id
    assert_receive {:conversation_event, ^id, :message}
    assert_receive {:conversation_event, ^id, :status}
    assert {:ok, _} = Ankole.Conversations.create(human.uid, request)
    refute_received {:conversation_event, _, _}
  end

  test "page conversations retain their identity, discoverability, and Agent context", %{
    human: human
  } do
    agent =
      Ankole.AIGatewayCase.background_agent_fixture(%{owner_principal_uid: human.uid}).principal

    {:ok, page} = Ankole.Pod.Pages.create(human.uid, %{title: "Team report"})
    request = Map.put(attrs(agent), :page_id, page.id)
    assert {:ok, first} = in_tx(fn -> Ankole.ConversationsFixtures.create(human.uid, request) end)
    assert first.conversation.page_id == page.id
    assert {:ok, [%{conversation: %{id: id}}]} = Conversations.list_for_page(human.uid, page.id)
    assert id == first.conversation.id
    assert {:ok, reopened} = Conversations.get(human.uid, id)
    assert reopened.messages == first.messages

    assert {:ok, context} = Ankole.Sessions.Context.resolve(agent.uid, first.session_id)
    assert context.conversation.page_id == page.id
    wire = Ankole.Sessions.TurnEnvelope.agent_context(context)
    assert wire.conversation.page_id == page.id
    assert wire.conversation.pod_instructions =~ "Current Page ID: #{page.id}"

    assert wire.conversation.pod_instructions =~
             "research reports are saved as editable Pod Pages by default"

    assert wire.conversation.pod_instructions =~ "explicitly requests a file format"

    input = Repo.get_by!(Signal, message_id: request.message_id)

    assert {:ok, %{job: job}} =
             Repo.transact(fn _repo ->
               Ankole.BackgroundAgentJobs.create_with_dispatch(%{
                 "source_signal_id" => input.id,
                 "agent_uid" => agent.uid,
                 "owner_session_id" => first.session_id,
                 "source_tool_call_id" => "page-chat-report",
                 "title" => "Update report",
                 "task" => "Update the current report Page.",
                 "reply_route" => %{"conversation_id" => id}
               })
             end)

    assert {:ok, job_context} =
             Ankole.Sessions.Context.resolve(
               agent.uid,
               Ankole.BackgroundAgentJobs.job_session_id(job.id)
             )

    job_wire = Ankole.Sessions.TurnEnvelope.agent_context(job_context)
    assert job_wire.conversation.page_id == page.id
    assert job_wire.conversation.pod_instructions == wire.conversation.pod_instructions

    assert {:error, :conversation_conflict} =
             in_tx(fn ->
               Ankole.ConversationsFixtures.create(human.uid, Map.delete(request, :page_id))
             end)

    {:ok, other_page} = Ankole.Pod.Pages.create(human.uid, %{title: "Other report"})
    assert {:ok, []} = Conversations.list_for_page(human.uid, other_page.id)

    assert {:error, :conversation_conflict} =
             in_tx(fn ->
               Ankole.ConversationsFixtures.create(human.uid, %{request | page_id: other_page.id})
             end)

    {:ok, _} = Repo.delete(page)
    assert {:ok, %{conversation: %{page_id: nil}}} = Conversations.get(human.uid, id)
    assert {:error, :page_unavailable} = Conversations.list_for_page(human.uid, page.id)
  end

  test "page chat creation and later input require the Human's current page access", %{
    human: human,
    agent: agent
  } do
    %{principal: owner} = human_fixture()

    {:ok, private} =
      Ankole.Pod.Pages.create(owner.uid, %{title: "Private report", private_owner_uid: owner.uid})

    request = Map.put(attrs(agent), :page_id, private.id)

    assert {:error, :page_unavailable} =
             in_tx(fn -> Ankole.ConversationsFixtures.create(human.uid, request) end)

    assert {:error, :page_unavailable} = Conversations.list_for_page(human.uid, private.id)
    assert Repo.aggregate(Conversation, :count) == 0

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(owner.uid, private.id, %{
        grants: [%{principal_uid: human.uid, role: "view"}]
      })

    assert {:ok, detail} =
             in_tx(fn -> Ankole.ConversationsFixtures.create(human.uid, request) end)

    {:ok, _} = Ankole.Pod.PagesFixtures.set_sharing(owner.uid, private.id, %{grants: []})

    assert {:error, :page_unavailable} =
             in_tx(fn ->
               Ankole.ConversationsFixtures.post(human.uid, detail.conversation.id, %{
                 message_id: Ecto.UUID.generate(),
                 text: "Change this report"
               })
             end)

    assert Repo.aggregate(Message, :count) == 1
  end

  defp attrs(agent) do
    %{
      conversation_id: Ecto.UUID.generate(),
      agent_uid: agent.uid,
      message_id: Ecto.UUID.generate(),
      text: "Help me plan this work"
    }
  end

  defp in_tx(fun), do: Repo.transact(fn _repo -> fun.() end)

  defp assert_no_adapter_rows do
    for schema <- [Binding, ExternalMessageRef, Intent],
        do: assert(Repo.aggregate(schema, :count) == 0)
  end
end
