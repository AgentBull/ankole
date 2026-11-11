defmodule Ankole.Pod.Chat.ReadSnapshotTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.Conversations
  alias Ankole.Pod.Chat.Presentation

  test "room list reads stay bounded as the number of rooms grows" do
    human = human_fixture().principal
    agent = agent_fixture(%{owner_principal_uid: human.uid}).principal
    actor = actor_fixture(human)
    Ankole.ConversationsFixtures.grant_chat(human.uid, agent.uid)

    for number <- 1..12 do
      assert {:ok, _} =
               Ankole.ConversationsFixtures.create(human.uid, %{
                 room_mode: :group,
                 conversation_id: Ash.UUIDv7.generate(),
                 message_id: Ash.UUIDv7.generate(),
                 agent_uid: agent.uid,
                 text: "Room #{number}"
               })
    end

    {one, one_count} =
      queries(fn ->
        Conversations.list_rooms(actor, limit: 1) |> Presentation.conversations()
      end)

    {many, many_count} =
      queries(fn ->
        Conversations.list_rooms(actor, limit: 12) |> Presentation.conversations()
      end)

    assert length(one) == 1
    assert length(many) == 12
    assert one_count > 0
    assert many_count <= one_count + 2, "one room: #{one_count}, twelve rooms: #{many_count}"
    assert many_count < 30
    assert Enum.all?(many, &(&1.rowStatus == "unread"))
  end

  test "detail projection keeps the queue and references from its original snapshot" do
    human = human_fixture().principal
    agent = agent_fixture(%{owner_principal_uid: human.uid}).principal
    actor = actor_fixture(human)
    Ankole.ConversationsFixtures.grant_chat(human.uid, agent.uid)

    assert {:ok, detail} =
             Ankole.ConversationsFixtures.create(human.uid, %{
               room_mode: :group,
               conversation_id: Ash.UUIDv7.generate(),
               message_id: Ash.UUIDv7.generate(),
               agent_uid: agent.uid,
               text: "Queued request"
             })

    id = detail.conversation.id
    [input] = detail.pending_inputs

    assert {:ok, current} =
             Conversations.update_queue(actor, id, %{
               agent_uid: agent.uid,
               action: "retract",
               message_id: input.message_id,
               expected_version: detail.queue_versions[agent.uid]
             })

    assert current.pending_inputs == []

    {projection, count} = queries(fn -> Presentation.detail(detail) end)
    assert count == 0

    assert [%{queueVersion: version, inputs: [%{messageID: message_id}]}] =
             projection.pendingQueues

    assert version == detail.queue_versions[agent.uid]
    assert message_id == input.message_id
  end

  test "a waiting_on_user background job yields streaming while the room Agent runs, then waiting_choice with inline pendingQuestions" do
    human = human_fixture().principal

    agent =
      Ankole.AIGatewayCase.background_agent_fixture(%{owner_principal_uid: human.uid}).principal

    actor = actor_fixture(human)
    Ankole.ConversationsFixtures.grant_chat(human.uid, agent.uid)

    assert {:ok, detail} =
             Ankole.ConversationsFixtures.create(human.uid, %{
               room_mode: :group,
               conversation_id: Ash.UUIDv7.generate(),
               message_id: Ash.UUIDv7.generate(),
               agent_uid: agent.uid,
               text: "Deploy staging"
             })

    session_id = Ankole.Sessions.Key.conversation(detail.conversation.id)
    source_signal = Ankole.WorkFixtures.service_source(agent.uid)

    assert {:ok, %{job: job}} =
             Ankole.SessionsCase.create_job_with_stub_driver(%{
               "source_signal_id" => source_signal.id,
               "agent_uid" => agent.uid,
               "owner_session_id" => session_id,
               "source_tool_call_id" => "tool-job-1",
               "title" => "Deploy staging",
               "task" => "Deploy staging and ask before migrating.",
               "reply_route" => %{
                 "binding_name" => "pod",
                 "conversation_id" => detail.conversation.id
               }
             })

    pending_metadata = %{
      "pending_user_input" => %{
        "questions" => [
          %{
            "id" => "q_env",
            "header" => "Target",
            "question" => "Which region should receive the canary first?",
            "options" => [
              %{"label" => "us-east-1", "description" => "Primary canary"},
              %{"label" => "eu-west-1", "description" => "Secondary canary"}
            ]
          }
        ]
      }
    }

    job =
      Ankole.Repo.update!(
        Ecto.Changeset.change(job,
          status: :waiting_on_user,
          runtime_thread_id: "thread-1",
          metadata: Map.merge(job.metadata || %{}, pending_metadata)
        )
      )

    idle_detail =
      %{
        detail
        | statuses: %{agent.uid => %{state: :idle, retry_at: nil}},
          linked_jobs: [job]
      }

    running_detail =
      %{
        idle_detail
        | statuses: %{agent.uid => %{state: :running, retry_at: nil}}
      }

    assert Presentation.conversation(running_detail).rowStatus == "streaming"
    assert Presentation.conversation(idle_detail).rowStatus == "waiting_choice"

    projected = Presentation.detail(idle_detail)

    assert [
             %{
               id: job_id,
               status: "waiting_on_user",
               pendingQuestions: [
                 %{
                   id: "q_env",
                   header: "Target",
                   question: "Which region should receive the canary first?",
                   options: [
                     %{label: "us-east-1", description: "Primary canary"},
                     %{label: "eu-west-1", description: "Secondary canary"}
                   ]
                 }
               ]
             }
           ] = projected.linkedRuns

    assert job_id == to_string(job.id)

    attention_ids =
      Conversations.list_rooms(actor, attention: true)
      |> Enum.map(& &1.conversation.id)

    assert detail.conversation.id in attention_ids
  end

  defp queries(fun) do
    observer = self()
    ref = make_ref()

    :ok =
      :telemetry.attach(
        ref,
        [:ankole, :repo, :query],
        fn _, _, _, _ ->
          if self() == observer, do: send(observer, ref)
        end,
        nil
      )

    try do
      value = fun.()
      {value, drain(ref, 0)}
    after
      :telemetry.detach(ref)
    end
  end

  defp drain(ref, count) do
    receive do
      ^ref -> drain(ref, count + 1)
    after
      0 -> count
    end
  end
end
