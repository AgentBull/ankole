defmodule Ankole.Sessions.NativeCronTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.{Conversations, Schedule}
  alias Ankole.Sessions.Presentation
  alias Ankole.Schedule.Schemas.CronSchedule

  setup do
    %{principal: human} = human_fixture()
    %{principal: agent} = agent_fixture(%{owner_principal_uid: human.uid})
    Ankole.ConversationsFixtures.grant_chat(human.uid, agent.uid)
    first = create_conversation(human.uid, agent.uid)
    second = create_conversation(human.uid, agent.uid)
    %{human: human, agent: agent, first: first, second: second}
  end

  test "renaming an inactive Agent preserves its Cron-owned Session", ctx do
    assert {:ok, %{cron_schedule: schedule}} =
             Schedule.create_cron_schedule(cron_attrs(ctx, [ctx.first.id]),
               created_by: %{
                 "principal_uid" => to_string(Ankole.ActorRef.from_principal(ctx.human))
               }
             )

    assert {:ok, workspace} =
             Repo.transact(fn ->
               Ankole.Sessions.Workspaces.ensure_in_tx(ctx.agent.uid, "cron:#{schedule.id}")
             end)

    assert {:ok, _} = Ankole.Principals.disable_agent(ctx.agent.uid)

    assert {:ok, %{principal: renamed}} =
             Ankole.Principals.rename(ctx.agent.uid, "renamed-cron-owner")

    assert Repo.reload!(workspace).agent_uid == renamed.uid
    assert Repo.reload!(schedule).agent_uid == renamed.uid
  end

  test "native schedules need no external binding and retain a native delivery on update",
       context do
    attrs = cron_attrs(context, [context.first.id])

    assert {:ok, %{cron_schedule: schedule}} =
             Schedule.create_cron_schedule(attrs,
               created_by: %{
                 "principal_uid" => to_string(Ankole.ActorRef.from_principal(context.human))
               }
             )

    assert is_nil(schedule.binding_name)

    assert {:ok, updated} =
             Schedule.update_cron_schedule(schedule.id, %{
               "delivery" => %{"quiet_success" => true}
             })

    assert is_nil(updated.binding_name)
    assert updated.delivery["targets"] == [%{"conversation_id" => context.first.id}]
    assert updated.delivery["quiet_success"] == true
    assert Repo.get!(CronSchedule, schedule.id).delivery == updated.delivery
  end

  test "a native target must contain the producing Agent", context do
    %{principal: other} = agent_fixture(%{owner_principal_uid: context.human.uid})
    Ankole.ConversationsFixtures.grant_chat(context.human.uid, other.uid)
    foreign = create_conversation(context.human.uid, other.uid)

    assert {:error, :conversation_not_found} =
             Schedule.create_cron_schedule(cron_attrs(context, [foreign.id]),
               created_by: %{
                 "principal_uid" => to_string(Ankole.ActorRef.from_principal(context.human))
               }
             )

    refute Repo.exists?(CronSchedule)
  end

  test "one cron signal can commit once per native target with its source provenance", context do
    {:ok, signal} = cron_signal(context, [context.first.id, context.second.id])

    assert {:ok, %{messages: messages}} =
             Repo.transact(fn ->
               Presentation.post_in_tx(signal, %Ankole.Conversations.Statement{
                 signal: signal,
                 text: "Shared report"
               })
             end)

    assert MapSet.new(Enum.map(messages, & &1.conversation_id)) ==
             MapSet.new([context.first.id, context.second.id])

    assert Enum.all?(
             messages,
             &(&1.session_id == signal.session_id and &1.signal_id == signal.id and
                 &1.author_uid == context.agent.uid)
           )

    assert {:ok, %{messages: same}} =
             Repo.transact(fn ->
               Presentation.post_in_tx(signal, %Ankole.Conversations.Statement{
                 signal: signal,
                 text: "Shared report"
               })
             end)

    assert MapSet.new(Enum.map(same, & &1.id)) == MapSet.new(Enum.map(messages, & &1.id))

    assert {:error, :conversation_conflict} =
             Repo.transact(fn ->
               Presentation.post_in_tx(signal, %Ankole.Conversations.Statement{
                 signal: signal,
                 text: "Changed report"
               })
             end)

    assert {:ok, first} =
             Conversations.get(
               Ankole.PrincipalsFixtures.actor_fixture(context.human.uid),
               context.first.id
             )

    assert Enum.map(first.messages, & &1.text) == ["Initial question", "Shared report"]
  end

  test "rollback commits neither a report nor a sequence gap", context do
    {:ok, signal} = cron_signal(context, [context.first.id])

    assert {:error, :abort} =
             Repo.transact(fn ->
               {:ok, %{messages: [_]}} =
                 Presentation.post_in_tx(signal, %Ankole.Conversations.Statement{
                   signal: signal,
                   text: "Uncommitted report"
                 })

               {:error, :abort}
             end)

    assert {:ok, %{messages: [message]}} =
             Repo.transact(fn ->
               Presentation.post_in_tx(signal, %Ankole.Conversations.Statement{
                 signal: signal,
                 text: "Committed report"
               })
             end)

    assert message.seq == 2
  end

  test "a rejected cron fire publishes a notice to every native target", context do
    assert :ok = Conversations.Events.subscribe(context.first.id)
    assert :ok = Conversations.Events.subscribe(context.second.id)
    {:ok, signal} = cron_signal(context, [context.first.id, context.second.id])

    assert {:ok, result} =
             Ankole.Sessions.Notices.finalize(
               {:error, {:model_profile_unavailable, "missing", :not_configured}},
               signal,
               DateTime.utc_now(:microsecond)
             )
             |> Ankole.Sessions.Run.after_finalization()

    assert result.signal.completed_at
    assert length(result.posted.messages) == 2
    assert Enum.all?(result.posted.messages, &(&1.kind == :notice))
    first_id = context.first.id
    second_id = context.second.id
    assert_receive {:conversation_event, ^first_id, :message}
    assert_receive {:conversation_event, ^second_id, :message}
  end

  test "a cron rejection records every external notice independently beside the native notice",
       context do
    {:ok, external} =
      Repo.transact(fn ->
        Ankole.Conversations.External.observe_conversation_in_tx(
          %{agent_uid: context.agent.uid},
          %{
            provider_conversation_id: "test:missing-route",
            title: "External room",
            external_kind: :im_group,
            reply_mode: :channel
          },
          DateTime.utc_now(:microsecond)
        )
      end)

    binding =
      Ankole.SignalsFixtures.binding_fixture(context.agent.uid, "unavailable-binding", :ignore,
        adapter: "missing-adapter"
      )

    targets = [
      %{"conversation_id" => context.first.id},
      %{
        "binding_id" => binding.id,
        "binding_name" => binding.name,
        "conversation_id" => external.id,
        "provider_thread_id" => "thread-one"
      },
      %{
        "binding_id" => binding.id,
        "binding_name" => binding.name,
        "conversation_id" => external.id,
        "provider_thread_id" => "thread-two"
      }
    ]

    {:ok, signal} = cron_signal(context, [context.first.id])

    signal =
      Repo.update!(
        Ecto.Changeset.change(signal,
          data: %{"wake_payload" => %{"delivery" => %{"targets" => targets}}}
        )
      )

    assert {:ok, result} =
             Ankole.Sessions.Notices.finalize(
               {:error, {:model_profile_unavailable, "missing", :not_configured}},
               signal,
               DateTime.utc_now(:microsecond)
             )

    assert length(result.posted.messages) == 1

    notices =
      Repo.all(
        from o in Ankole.Conversations.Delivery.Intent, where: o.source_signal_id == ^signal.id
      )

    assert length(notices) == 2

    assert MapSet.new(Enum.map(notices, & &1.provider_thread_id)) ==
             MapSet.new(["thread-one", "thread-two"])

    assert length(Enum.uniq(Enum.map(notices, & &1.outbound_key))) == 2
  end

  defp create_conversation(human, agent) do
    {:ok, detail} =
      Ankole.ConversationsFixtures.create(human, %{
        conversation_id: Ecto.UUID.generate(),
        message_id: Ecto.UUID.generate(),
        agent_uid: agent,
        text: "Initial question"
      })

    detail.conversation
  end

  defp recurrence do
    %{
      "kind" => "every",
      "every_ms" => 3_600_000,
      "anchor_at" =>
        DateTime.to_iso8601(DateTime.add(DateTime.utc_now(:microsecond), -1, :second)),
      "timezone" => "UTC"
    }
  end

  defp cron_attrs(context, ids) do
    %{
      agent_uid: context.agent.uid,
      owner_session_id: Ankole.Sessions.Key.conversation(context.first.id),
      name: "Native monitor",
      schedule: recurrence(),
      payload: %{"task" => "Report changes"},
      delivery: %{"targets" => Enum.map(ids, &%{"conversation_id" => &1})},
      idempotency_key: Ecto.UUID.generate()
    }
  end

  defp cron_signal(context, ids) do
    with {:ok, %{cron_schedule: cron}} <-
           Schedule.create_cron_schedule(cron_attrs(context, ids),
             created_by: %{
               "principal_uid" => to_string(Ankole.ActorRef.from_principal(context.human))
             }
           ),
         {:ok, %{signal: signal}} <- Schedule.fire_cron(cron.id, now: cron.next_fire_at),
         do: {:ok, signal}
  end
end
