defmodule Ankole.Sessions.MixedScheduleDeliveryTest do
  use Ankole.SessionsCase

  alias Ankole.Conversations.Delivery.Preview
  alias Ankole.Sessions.{Admission, Model, Presentation, Run, Scheduled, Tools}

  setup context do
    Ankole.SessionsCase.use_mock_signal_provider_plugin(context)
  end

  test "a real native-primary schedule finalizes both targets and recovers the external delivery" do
    %{principal: human} = Ankole.PrincipalsFixtures.human_fixture()
    %{principal: agent} = agent_fixture(%{owner_principal_uid: human.uid})
    Ankole.ConversationsFixtures.grant_chat(human.uid, agent.uid)
    binding_fixture(agent.uid, "secondary", :ignore, adapter: "mock-provider")

    assert {:ok, native} =
             Ankole.ConversationsFixtures.create(human.uid, %{
               conversation_id: Ecto.UUID.generate(),
               message_id: Ecto.UUID.generate(),
               agent_uid: agent.uid,
               text: "Set up a report"
             })

    assert {:ok, external} =
             Repo.transact(fn ->
               Ankole.Conversations.External.observe_conversation_in_tx(
                 %{agent_uid: agent.uid},
                 %{
                   provider_conversation_id: "mock:mixed-report",
                   title: "External reports",
                   external_kind: :im_group,
                   reply_mode: :channel
                 },
                 @base_time
               )
             end)

    targets = [
      %{"conversation_id" => native.conversation.id},
      %{
        "conversation_id" => external.id,
        "binding_name" => "secondary",
        "provider_thread_id" => "secondary-thread"
      }
    ]

    source = Ankole.WorkFixtures.service_source(agent.uid)

    assert {:ok, %{cron_schedule: cron}} =
             Ankole.Schedule.create_cron_schedule(
               %{
                 agent_uid: agent.uid,
                 owner_session_id: Ankole.Sessions.Key.conversation(native.conversation.id),
                 name: "mixed-report",
                 idempotency_key: Ecto.UUID.generate(),
                 schedule: %{
                   "kind" => "every",
                   "every_ms" => 60_000,
                   "anchor_at" => DateTime.to_iso8601(@base_time),
                   "timezone" => "UTC"
                 },
                 payload: %{"task" => "Prepare one report"},
                 delivery: %{"targets" => targets}
               },
               now: @base_time,
               created_by: %{"signal_id" => source.id}
             )

    assert {:ok, %{signal: event}} =
             Ankole.Schedule.fire_cron(cron.id, now: cron.next_fire_at)

    assert event.producer == :kernel
    assert event.reply_binding_name == nil
    assert event.conversation_id == native.conversation.id
    assert Scheduled.produced_signal?(event)
    refute Preview.channel_reply_eligible?(event)
    assert {:ok, [primary, secondary]} = Presentation.targets_in_tx(event)
    assert primary.kind == :native
    assert secondary.kind == :external
    assert secondary.binding_name == "secondary"
    assert Ankole.Conversations.Target.reply_eligible?(secondary, event)

    refute Ankole.Conversations.Target.reply_eligible?(secondary, %{
             event
             | type: "unknown.external"
           })

    refute Ankole.Conversations.Target.reply_eligible?(%{secondary | binding_name: nil}, event)

    assert {:ok, run} =
             Admission.admit(%{agent_uid: agent.uid, session_id: event.session_id}, event)

    {tools, hosted} =
      Scheduled.tools(run, [%{"name" => "reply_attachment"}], [%{"type" => "image_generation"}])

    assert Enum.any?(tools, &(&1["name"] == "reply_attachment"))
    assert Enum.any?(hosted, &(&1["type"] == "image_generation"))
    assert :ok = Presentation.start(run, self())
    assert Preview.lookup(event.id) == []
    assert {:ok, {:preparing, run}} = Model.prepare(run)

    call = %{
      "type" => "function_call",
      "name" => "finish_scheduled",
      "call_id" => "finish",
      "arguments" =>
        Ankole.JSON.encode!(%{"outcome" => "reply", "reply" => "Report for both destinations"})
    }

    response = complete_response_items(agent.uid, event, [call])
    run = %{run | model_response: response, calls: [call], round_calls: [call]}
    assert {:ok, tool, args} = Tools.prepare(run, call)
    result = Tools.execute(run, call, tool, args)
    refute result.is_error
    assert {:ok, journal} = Run.record_round(%{run | results: %{call["call_id"] => result}})
    assert {:ok, {_state, run}} = Run.restore(run)
    run = %{run | event: Repo.get!(Signal, event.id), anchor: journal.message.id}

    assert {:ok, %{status: :completed, posted: %{messages: [message], intents: [intent]}}} =
             Run.finalize(run, :loop_finished)

    assert message.conversation_id == native.conversation.id
    assert message.text == "Report for both destinations"
    assert intent.conversation_id == external.id
    assert intent.binding_name == "secondary"
    assert intent.provider_thread_id == "secondary-thread"
    assert intent.operation == :post
    assert intent.payload["text"] == message.text
    assert get_in(intent.payload, ["metadata", "delivery_target", "primary"]) == false
    refute Map.has_key?(intent.payload, "reply_presentation")
    assert intent.target_provider_message_id == nil
    assert {:error, :run_closed} = Run.finalize(run, :loop_finished)

    assert Repo.aggregate(
             from(m in Ankole.Conversations.Message, where: m.signal_id == ^event.id),
             :count
           ) == 1

    assert Repo.aggregate(from(i in Intent, where: i.source_signal_id == ^event.id), :count) == 1

    # Each dispatch is a fresh process and loads its own durable intent by key.
    retryable =
      delivery_adapter([:post_entry], fn _ ->
        {:error, {:reply_delivery, :retryable, %{"code" => "offline"}}}
      end)

    assert {:ok, %Intent{status: :failed} = failed} =
             Task.async(
               Repo.bind_tenant(fn ->
                 Ankole.Conversations.Delivery.dispatch(
                   agent.uid,
                   "secondary",
                   intent.outbound_key,
                   retryable
                 )
               end)
             )
             |> Task.await()

    successful =
      delivery_adapter([:post_entry], fn delivered ->
        assert delivered.conversation_id == external.id
        assert delivered.provider_thread_id == "secondary-thread"
        {:ok, %{created_provider_message_id: "mixed-delivered", raw_payload: %{}}}
      end)

    assert {:ok, %Intent{status: :sent, attempt_count: 2}} =
             Task.async(
               Repo.bind_tenant(fn ->
                 Ankole.Conversations.Delivery.dispatch(
                   agent.uid,
                   "secondary",
                   intent.outbound_key,
                   successful,
                   now: DateTime.add(failed.next_attempt_at, 1, :second)
                 )
               end)
             )
             |> Task.await()

    assert Repo.aggregate(
             from(m in Ankole.Conversations.Message,
               where: m.conversation_id == ^native.conversation.id and m.signal_id == ^event.id
             ),
             :count
           ) == 1
  end

  defp complete_response_items(subject_uid, event, items) do
    {:ok, conversation} =
      Ankole.AIGatewayCase.ensure_conversation(subject_uid, event.session_id)

    {:ok, response_run} =
      start_response_run(%{
        subject_uid: subject_uid,
        conversation_id: conversation.id,
        request_items: [
          %{
            "type" => "message",
            "role" => "user",
            "content" => [%{"type" => "input_text", "text" => "finish this"}]
          }
        ],
        metadata: %{"request_metadata" => %{"signal_id" => event.id}}
      })

    assert {:ok, final} =
             Ankole.AIGateway.ResponseCommit.commit_complete(response_run, items, %{})

    final
  end
end
