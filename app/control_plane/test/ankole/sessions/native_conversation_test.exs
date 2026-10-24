defmodule Ankole.Sessions.NativeConversationTest do
  use Ankole.DataCase, async: false

  import Ankole.SessionsCase, only: [agent_fixture: 1]
  import Ankole.AIGatewayCase, only: [start_response_run: 1]

  alias Ankole.AIGateway.ResponseCommit
  alias Ankole.Conversations
  alias Ankole.Conversations.Message
  alias Ankole.Sessions.Admission
  alias Ankole.Sessions.Commands
  alias Ankole.Sessions.Model
  alias Ankole.Sessions.Notices
  alias Ankole.Sessions.Run
  alias Ankole.Signals.Signal
  alias Ankole.Signals.Binding
  alias Ankole.Conversations.Delivery.Intent

  setup do
    %{principal: human} = Ankole.PrincipalsFixtures.human_fixture()
    %{principal: agent} = agent_fixture(%{owner_principal_uid: human.uid})
    id = Ecto.UUID.generate()

    assert {:ok, detail} =
             Repo.transact(fn _repo ->
               Ankole.ConversationsFixtures.create(human.uid, %{
                 conversation_id: id,
                 agent_uid: agent.uid,
                 message_id: Ecto.UUID.generate(),
                 text: "Explain the current project."
               })
             end)

    event = Repo.one!(Signal)
    key = %{agent_uid: agent.uid, session_id: event.session_id}
    assert :ok = Conversations.Events.subscribe(id)
    assert :ok = Ankole.Sessions.Events.subscribe(key.agent_uid, key.session_id)

    %{human: human, agent: agent, id: id, event: event, key: key, detail: detail}
  end

  test "native input has the Human's authority and starts without an IM route", context do
    assert Ankole.Sessions.status(context.key).state == :queued
    run = prepare(context)
    assert run.event.human_uid == context.human.uid
    assert run.event.conversation_id == context.id
    assert Ankole.Sessions.status(context.key).state == :running
    assert_receive {:session_event, uid, session, :status}
    assert uid == context.agent.uid
    assert session == context.key.session_id

    assert Ankole.Sessions.Prompt.Input.text(Signal.envelope(run.event), run.event.type) ==
             "Explain the current project."

    assert_no_adapter_rows()
  end

  test "completion commits one public reply and emits message and idle status", context do
    run = context |> prepare() |> respond("The project has one durable owner.")
    assert_receive {:session_event, _, _, :status}
    assert {:ok, result} = Run.finalize(run)

    assert %Message{text: "The project has one durable owner.", kind: :message} =
             result.posted.messages |> List.first()

    assert {:ok, detail} = Conversations.get(context.human.uid, context.id)
    assert Enum.map(detail.messages, & &1.seq) == [1, 2]
    reply = List.last(detail.messages)
    assert reply.author_uid == context.agent.uid
    assert reply.signal_id == context.event.id
    assert reply.session_id == context.key.session_id
    assert reply.reply_to_message_id == hd(detail.messages).id
    assert Ankole.Sessions.status(context.key) == %{state: :idle, retry_at: nil}
    assert Repo.reload!(context.event).completed_at
    assert_receive {:conversation_event, _, :message}
    assert_receive {:session_event, _, _, {:turn_completed, _, :loop_finished}}
    refute_received {:session_event, _, _, :status}
    assert {:error, :run_closed} = Run.finalize(run)
    assert Repo.aggregate(Message, :count) == 2
    assert_no_adapter_rows()
  end

  test "silent completion closes its signal without a message event", context do
    run = prepare(context)
    assert_receive {:session_event, _, _, :status}
    assert {:ok, _} = Run.finalize(run, :silent)
    assert Ankole.Sessions.status(context.key).state == :idle
    assert Repo.aggregate(Message, :count) == 1
    refute_receive {:conversation_event, _, :message}
    assert_receive {:session_event, _, _, {:turn_completed, _, :silent}}
    refute_received {:session_event, _, _, :status}
    assert_no_adapter_rows()
  end

  test "dead letter is an immutable notice in the native conversation", context do
    run = prepare(context)
    assert {:ok, result} = Run.finalize(run, :dead_letter, %{"code" => "test_failure"})
    assert %Message{kind: :notice, text: text} = result.posted.messages |> List.first()
    assert is_binary(text) and text != ""
    assert Repo.reload!(context.event).status == :dead_letter
    assert Ankole.Sessions.status(context.key).state == :idle
    assert_receive {:conversation_event, _, :message}
    assert_no_adapter_rows()
  end

  test "a retry records its deadline and broadcasts after commit", context do
    run = prepare(context)
    assert_receive {:session_event, _, _, :status}
    assert {:ok, event} = Run.defer_retry(run, %{"code" => "temporary_failure"})

    assert Ankole.Sessions.status(context.key) == %{
             state: :retrying,
             retry_at: event.available_at
           }

    assert_receive {:session_event, _, _, :status}
    refute_receive {:conversation_event, _, :message}
  end

  test "a retry in a caller transaction publishes only after commit", context do
    run = prepare(context)
    assert_receive {:session_event, _, _, :status}
    error = %{"code" => "temporary_failure"}
    now = DateTime.utc_now(:microsecond)

    assert_raise Ankole.Errors.Framework.NestedOperation, ~r/must run at the top level/, fn ->
      Repo.transact(fn _repo -> Run.defer_retry(run, error, now) end)
    end

    assert {:error, :rollback} =
             Repo.transact(fn ->
               assert {:ok, _} = Run.defer_retry_in_tx(run, error, now)
               refute_receive {:conversation_event, _, _}
               refute_receive {:session_event, _, _, _}
               {:error, :rollback}
             end)

    assert Repo.reload!(context.event).available_at == run.event.available_at
    refute_receive {:conversation_event, _, _}
    refute_receive {:session_event, _, _, _}

    assert {:ok, retried} =
             Repo.transact(fn -> Run.defer_retry_in_tx(run, error, now) end)

    refute_receive {:conversation_event, _, _}
    refute_receive {:session_event, _, _, _}
    Run.after_finalization({:ok, %{signal: retried, status: :deferred}})
    assert_receive {:session_event, _, _, :status}

    assert Ankole.Sessions.status(context.key) == %{
             state: :retrying,
             retry_at: retried.available_at
           }
  end

  test "ready input and a running turn take priority over an earlier waiting retry", context do
    run = prepare(context)
    assert {:ok, retry} = Run.defer_retry(run, %{"code" => "temporary_failure"})

    assert Ankole.Sessions.status(context.key) == %{
             state: :retrying,
             retry_at: retry.available_at
           }

    followup = queued_followup(context)
    assert Ankole.Sessions.status(context.key) == %{state: :queued, retry_at: nil}
    assert {:ok, current} = Admission.admit(context.key, followup)
    assert Ankole.Sessions.status(context.key) == %{state: :running, retry_at: nil}

    assert {:ok, _} = Run.finalize(current, :silent)

    assert Ankole.Sessions.status(context.key) == %{
             state: :retrying,
             retry_at: retry.available_at
           }

    assert_no_adapter_rows()
  end

  test "rollback publishes no completion and leaves no public reply", context do
    run = context |> prepare() |> respond("Only committed text is public.")
    assert_receive {:session_event, _, _, :status}

    assert {:error, :rollback} =
             Repo.transact(fn ->
               assert {:ok, _} = Run.finalize_in_tx(run, :loop_finished, nil)
               refute_receive {:conversation_event, _, _}
               refute_receive {:session_event, _, _, _}
               {:error, :rollback}
             end)

    assert Repo.aggregate(Message, :count) == 1
    assert is_nil(Repo.reload!(context.event).completed_at)
    refute_receive {:conversation_event, _, _}
    refute_receive {:session_event, _, _, _}
    assert {:ok, _} = Run.finalize(run)
    assert_receive {:conversation_event, _, :message}
    assert_no_adapter_rows()
  end

  test "native follow-up is steered into the current Run and consumed with it", context do
    run = prepare(context)
    text = "Focus on the queue instead."

    assert {:ok, _} =
             Repo.transact(fn _repo ->
               Ankole.ConversationsFixtures.post(context.human.uid, context.id, %{
                 message_id: Ecto.UUID.generate(),
                 text: text
               })
             end)

    followup = Repo.one!(from(e in Signal, where: e.id != ^context.event.id))
    assert Commands.injectable?(followup)
    assert Ankole.Conversations.Route.current_input_signal_id(run) == context.event.id

    assert {:ok, [injected], run} =
             Run.inject_pending(%{run | pending_event_ids: [followup.id]}, fn _ -> true end)

    assert injected.id == followup.id
    assert run.steer_event_ids == [followup.id]
    assert run.signal_id == context.event.id
    assert Ankole.Conversations.Route.current_input_signal_id(run) == followup.id
    assert List.last(run.input)["content"] |> Enum.any?(&(&1["text"] == text))
    run = respond(run, "The queue is durable.")

    assert Ankole.Sessions.response_signal_ids(%{
             response_id: Run.response_id(run.model_response),
             metadata: Run.metadata(run)
           }) == [context.event.id, followup.id]

    assert {:ok, result} = Run.finalize(run)
    assert result.posted.messages |> List.first() |> Map.fetch!(:signal_id) == followup.id
    assert Repo.reload!(context.event).completed_at
    assert Repo.reload!(followup).completed_at
    assert Repo.aggregate(Message, :count) == 3
    assert_no_adapter_rows()
  end

  test "native model conversations are not daily-reset candidates", context do
    run = prepare(context)

    assert {:ok, %{due_sessions: 0, signals: []}} =
             Ankole.Sessions.SessionReset.enqueue_daily_session_resets(
               DateTime.add(DateTime.utc_now(:microsecond), 1, :day)
             )

    assert run.conversation.conversation_key == context.key.session_id
  end

  test "inbox authorization publishes a suspended follow-up notice after commit", context do
    prepare(context)
    assert_receive {:session_event, _, _, :status}
    followup = queued_followup(context)
    suspend_tenant()

    assert {:ok, %Signal{producer: :kernel, completed_at: %DateTime{}}} =
             Admission.authorize_event(followup)

    assert %Message{kind: :notice} = Repo.get_by!(Message, signal_id: followup.id)
    assert_receive {:conversation_event, _, :message}
    assert_receive {:session_event, _, _, :status}
    assert is_nil(Repo.reload!(context.event).completed_at)
    assert_no_adapter_rows()
  end

  test "injection preserves suspended follow-up effects and suppresses them on rollback",
       context do
    run = prepare(context)
    assert_receive {:session_event, _, _, :status}
    followup = queued_followup(context)
    suspend_tenant()

    assert {:error, :rollback} =
             Repo.transact(fn ->
               assert {:ok, {[], [_]}} =
                        Run.inject_in_tx(run, [followup], DateTime.utc_now(:microsecond))

               refute_receive {:conversation_event, _, _}
               refute_receive {:session_event, _, _, _}
               {:error, :rollback}
             end)

    assert is_nil(Repo.reload!(followup).completed_at)
    refute Repo.get_by(Message, signal_id: followup.id)

    assert {:ok, []} = Run.inject(run, [followup])
    assert %Message{kind: :notice} = Repo.get_by!(Message, signal_id: followup.id)
    assert_receive {:conversation_event, _, :message}
    assert_receive {:session_event, _, _, :status}
    assert Repo.reload!(followup).completed_at
    assert is_nil(Repo.reload!(context.event).completed_at)
    assert_no_adapter_rows()
  end

  test "admission failure leaves a visible native notice", context do
    assert {:ok, result} =
             Notices.finalize(
               {:error, {:model_profile_unavailable, "primary", :not_configured}},
               context.event,
               DateTime.utc_now(:microsecond)
             )
             |> Run.after_finalization()

    assert result.signal.completed_at
    assert %Message{kind: :notice} = List.first(result.posted.messages)
    assert_receive {:conversation_event, _, :message}
    assert_no_adapter_rows()
  end

  test "native turns advertise attachment delivery and image generation", context do
    run = prepare(context)
    assert Enum.any?(run.tools, &(&1.name == "reply_attachment"))

    assert {[%{"name" => "reply_attachment"}],
            [%{"type" => "image_generation"}, %{"type" => "brain", "inject" => true}]} =
             Ankole.Sessions.Main.tools(
               run,
               [%{"name" => "reply_attachment"}],
               [%{"type" => "image_generation"}, %{"type" => "brain"}]
             )

    assert Ankole.Sessions.Main.instructions(run) =~
             "deliver it with reply_attachment using drive_path"
  end

  test "attachment-only completion commits a native message through the real run owner",
       context do
    attachment =
      Ankole.FilesFixtures.sent_attachment_fixture(
        context.agent.uid,
        "report.pdf",
        "PDF result",
        "application/pdf"
      )

    run = prepare(context)

    assert {:ok, response} =
             start_response_run(%{
               subject_uid: run.agent_uid,
               conversation_id: run.conversation.id,
               round_state: run,
               metadata: %{"request_metadata" => Run.metadata(run)}
             })

    assert {:ok, response} =
             ResponseCommit.commit_complete(response, [
               %{
                 "type" => "function_call",
                 "name" => "reply_attachment",
                 "call_id" => "call-file",
                 "arguments" => "{}"
               },
               %{
                 "type" => "function_call_output",
                 "call_id" => "call-file",
                 "output" =>
                   Torque.encode!(%{"tool" => "reply_attachment", "attachments" => [attachment]})
               }
             ])

    assert {:ok, result} = Run.finalize(%{run | model_response: response, anchor: response.id})
    assert [%Message{text: nil, attachments: [^attachment]}] = result.posted.messages

    {:ok, target} = Ankole.Conversations.Target.for_reply(context.event)

    statement = %Ankole.Conversations.Statement{
      signal: context.event,
      completion: %{final_text: " \n", clarify_prompt: nil, attachments: [attachment]}
    }

    assert {:ok, %{messages: [%Message{text: nil, attachments: [^attachment]}]}} =
             Repo.transact(fn -> Conversations.post_in_tx(target, statement) end)

    assert Repo.aggregate(Message, :count) == 2
    assert_no_adapter_rows()
  end

  test "a native reply records page links", context do
    page_id = Ankole.Kernel.gen_uuid_v7()
    run = context |> prepare() |> respond("Read [the report](ankole:page/#{page_id}).")
    assert {:ok, result} = Run.finalize(run)
    assert [%Message{links: [%{"kind" => "page", "id" => ^page_id}]}] = result.posted.messages
    assert_no_adapter_rows()
  end

  test "native attachment ownership failure rolls back the message", context do
    attachment = %{
      "path" => "sent/missing.pdf",
      "blob_ref" => String.duplicate("0", 64),
      "name" => "missing.pdf",
      "size" => 4,
      "mime_type" => "application/pdf"
    }

    {:ok, target} = Ankole.Conversations.Target.for_reply(context.event)

    statement = %Ankole.Conversations.Statement{
      signal: context.event,
      completion: %{final_text: nil, clarify_prompt: nil, attachments: [attachment]}
    }

    assert {:error, {:reply_attachment_not_in_drive, "sent/missing.pdf"}} =
             Repo.transact(fn ->
               Conversations.post_in_tx(target, statement)
             end)

    assert Repo.aggregate(Message, :count) == 1
    assert_no_adapter_rows()
  end

  test "deleting a native UUID retires its model identity and rejects another Human replay",
       context do
    run = context |> prepare() |> respond("Private history from the first Human")
    assert {:ok, _} = Run.finalize(run)
    old_id = run.conversation.id
    assert {:ok, _} = Conversations.delete(context.human.uid, context.id)
    assert %{ended_at: %DateTime{}} = Repo.get!(Ankole.AIGateway.Schemas.Conversation, old_id)

    other = Ankole.PrincipalsFixtures.human_fixture().principal

    attrs = %{
      conversation_id: context.id,
      agent_uid: context.agent.uid,
      message_id: Ecto.UUID.generate(),
      text: "Start a new conversation"
    }

    assert {:error, :conversation_conflict} =
             Ankole.ConversationsFixtures.create(other.uid, attrs)

    new_id = Ecto.UUID.generate()

    assert {:ok, _} =
             Ankole.ConversationsFixtures.create(other.uid, %{attrs | conversation_id: new_id})

    fresh =
      Ankole.AIGateway.Conversations.list_active_conversations(
        subject_uid: context.agent.uid,
        conversation_key: Ankole.Sessions.Key.conversation(new_id)
      )

    assert [conversation] = fresh
    assert conversation.id != old_id

    assert Repo.aggregate(
             from(m in Ankole.AIGateway.Schemas.Message,
               where: m.conversation_id == ^conversation.id
             ),
             :count
           ) == 0
  end

  test "a retained Job route cannot deliver into a recreated native identity", context do
    parent = prepare(context)

    assert {:ok, heavy} =
             Ankole.AIAgent.ModelProfiles.get_model_profile(context.agent.uid, "heavy")

    assert {:ok, _} =
             Ankole.AIAgent.ModelProfiles.put_model_profile(context.agent.uid, "coding", %{
               provider_id: heavy["provider_id"],
               model: heavy["model"]
             })

    assert {:ok, %{job: job, dispatch_event: dispatch}} =
             Ankole.BackgroundAgentJobs.create_with_dispatch(%{
               "agent_uid" => context.agent.uid,
               "owner_session_id" => context.event.session_id,
               "source_signal_id" => context.event.id,
               "source_tool_call_id" => Ecto.UUID.generate(),
               "title" => "Retained native result",
               "task" => "Prepare a private report for the first Human.",
               "reply_route" => Ankole.Conversations.Route.snapshot(parent)
             })

    assert {:ok, _} = Run.finalize(parent, :silent)
    assert {:error, :conversation_busy} = Conversations.delete(context.human.uid, context.id)

    assert {:ok, _} =
             Ankole.BackgroundAgentJobs.request_stop(job.id, %{"agent_uid" => context.agent.uid})

    assert Repo.reload!(dispatch).completed_at
    assert Repo.reload!(job).reply_route["conversation_id"] == context.id
    assert {:ok, _} = Conversations.delete(context.human.uid, context.id)
    other = Ankole.PrincipalsFixtures.human_fixture().principal

    assert {:error, :conversation_conflict} =
             Ankole.ConversationsFixtures.create(other.uid, %{
               conversation_id: context.id,
               agent_uid: context.agent.uid,
               message_id: Ecto.UUID.generate(),
               text: "Receive the old report"
             })

    assert {:error, :background_agent_job_terminal} =
             Ankole.BackgroundAgentJobs.request_complete(job.id, %{
               "agent_uid" => context.agent.uid,
               "result_summary" => "A private report that arrived late"
             })

    assert {:error, _} = Ankole.Conversations.Target.for_reply(dispatch)
    assert Repo.aggregate(Message, :count) == 0
  end

  test "retired native identity remains protected by Signal facts before its first model turn",
       context do
    assert {:ok, _} =
             Repo.transact(fn ->
               Ankole.Sessions.Queue.mark_event_completed_in_tx(
                 context.event,
                 DateTime.utc_now(:microsecond)
               )
             end)

    assert {:ok, _} = Conversations.delete(context.human.uid, context.id)

    [history] =
      Repo.all(
        from c in Ankole.AIGateway.Schemas.Conversation,
          where:
            c.subject_uid == ^context.agent.uid and
              c.conversation_key == ^context.event.session_id
      )

    assert Repo.aggregate(
             from(m in Ankole.AIGateway.Schemas.Message,
               where: m.conversation_id == ^history.id
             ),
             :count
           ) == 0

    Repo.delete!(history)
    other = Ankole.PrincipalsFixtures.human_fixture().principal

    assert {:error, :conversation_conflict} =
             Ankole.ConversationsFixtures.create(other.uid, %{
               conversation_id: context.id,
               agent_uid: context.agent.uid,
               message_id: Ecto.UUID.generate(),
               text: "Retry a retired identity"
             })
  end

  defp prepare(context) do
    assert {:ok, run} = Admission.admit(context.key, context.event)
    assert {:ok, {:preparing, run}} = Model.prepare(run)
    run
  end

  defp queued_followup(context) do
    assert {:ok, _} =
             Repo.transact(fn _repo ->
               Ankole.ConversationsFixtures.post(context.human.uid, context.id, %{
                 message_id: Ecto.UUID.generate(),
                 text: "A follow-up before suspension."
               })
             end)

    Repo.one!(from(e in Signal, where: e.id != ^context.event.id))
  end

  defp suspend_tenant do
    Repo.get!(Ankole.Tenants.Tenant, Repo.tenant_id!())
    |> Ecto.Changeset.change(suspended_at: DateTime.utc_now(:microsecond))
    |> Repo.update!()
  end

  defp respond(run, text) do
    assert {:ok, response} =
             start_response_run(%{
               subject_uid: run.agent_uid,
               conversation_id: run.conversation.id,
               round_state: run,
               metadata: %{"request_metadata" => Run.metadata(run)}
             })

    assert {:ok, response} =
             ResponseCommit.commit_complete(response, [%{"type" => "output_text", "text" => text}])

    %{run | model_response: response, anchor: response.id}
  end

  defp assert_no_adapter_rows do
    for schema <- [Binding, Ankole.Conversations.ExternalMessageRef, Intent],
        do: assert(Repo.aggregate(schema, :count) == 0)
  end
end
