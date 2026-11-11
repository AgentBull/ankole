defmodule Ankole.IssuesTest do
  use Ankole.DataCase, async: false
  import Ecto.Query
  import Ankole.PrincipalsFixtures

  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.Conversations
  alias Ankole.Issues
  alias Ankole.Signals.Signal

  setup do
    owner = human_fixture(%{display_name: "Alice"}).principal |> actor_fixture()
    outsider = human_fixture(%{display_name: "Carol"}).principal |> actor_fixture()

    agent =
      Ankole.SessionsCase.agent_fixture(%{
        owner_principal_uid: owner.principal.uid,
        display_name: "Research Agent"
      }).principal

    Ankole.ConversationsFixtures.grant_chat(owner.principal.uid, agent.uid)
    %{owner: owner, outsider: outsider, agent: agent}
  end

  defp inputs(room_id) do
    Repo.all(
      from(s in Signal, where: s.conversation_id == ^room_id, order_by: [asc: s.queue_sequence])
    )
  end

  # The Agent's turn ends: every open input of the room completes.
  defp settle(room_id) do
    {:ok, :settled} =
      Repo.transact(fn ->
        [conversation_id: room_id, status: [in: [:queued, :running]]]
        |> Ankole.Signals.lock_signals_in_tx()
        |> Enum.each(fn signal ->
          {:ok, _} = Ankole.Sessions.Queue.complete_signal_in_tx(signal, [])
        end)

        {:ok, :settled}
      end)
  end

  defp start_job(owner, agent_uid, room_id, title) do
    {:ok, _} =
      BackgroundAgentJobs.create_with_dispatch(%{
        "agent_uid" => agent_uid,
        "owner_session_id" => Ankole.Sessions.Key.conversation(room_id),
        "created_by" => %{
          "principal_uid" => to_string(Ankole.ActorRef.from_principal(owner.principal))
        },
        "source_tool_call_id" => "tool-" <> title,
        "title" => title,
        "task" => "Do the work.",
        "reply_route" => %{"conversation_id" => room_id}
      })

    Repo.one!(from(job in Job, where: job.title == ^title, select: job.id))
  end

  defp chat_room(owner, agent_uid) do
    room_id = Ankole.Ecto.UUIDv7.autogenerate()

    {:ok, _} =
      Ankole.ConversationsFixtures.create(owner.principal, %{
        conversation_id: room_id,
        message_id: Ankole.Ecto.UUIDv7.autogenerate(),
        agent_uid: agent_uid,
        text: "Compare the three vendors and write a report."
      })

    room_id
  end

  test "a new Issue opens a room and hands its request to the Agent as the creator's message",
       ctx do
    assert {:ok, item} =
             Issues.create(ctx.owner, %{
               title: "Survey why teams churn",
               description: "Read the last quarter's cancellation notes.",
               agent_uid: ctx.agent.uid
             })

    assert %{status: :working, tracked: true, description: nil, runs: []} = item
    assert item.agent == %{uid: ctx.agent.uid, name: "Research Agent"}

    assert {:ok,
            %{
              title: "Survey why teams churn",
              room_mode: :dm,
              dm_colleague_uid: nil,
              title_customized: true
            }} = Conversations.get_conversation(item.id)

    assert [%Signal{type: "conversation.message.addressed"} = input] = inputs(item.id)
    assert input.agent_uid == ctx.agent.uid
    assert input.session_id == Ankole.Sessions.Key.conversation(item.id)
    assert input.sender_key == ctx.owner.principal.uid
    assert input.authorization_kind == "human"

    assert input.data["text"] ==
             "Survey why teams churn\n\nRead the last quarter's cancellation notes."

    assert {:ok, [%{id: id}]} = Issues.list(ctx.owner)
    assert id == item.id

    assert {:error, :issue_not_found} = Issues.get(ctx.outsider, item.id)
    assert {:ok, []} = Issues.list(ctx.outsider)
  end

  test "a later message in an Issue's room reaches its Agent as a request to answer", ctx do
    assert {:ok, item} =
             Issues.create(ctx.owner, %{title: "Churn report", agent_uid: ctx.agent.uid})

    settle(item.id)

    # The composer of the room names no Agent, as a person who just types does.
    assert {:ok, _} =
             Ankole.ConversationsFixtures.post(ctx.owner.principal, item.id, %{
               message_id: Ankole.Ecto.UUIDv7.autogenerate(),
               text: "Add last month's numbers."
             })

    assert [_request, %Signal{type: "conversation.message.addressed"} = follow_up] =
             inputs(item.id)

    assert follow_up.agent_uid == ctx.agent.uid
    assert follow_up.data["text"] == "Add last month's numbers."
    refute follow_up.data["optional_reply"]
  end

  test "an Issue that waits keeps its request until a person starts it", ctx do
    assert {:ok, item} =
             Issues.create(ctx.owner, %{
               title: "Pricing pages",
               description: "A first draft.",
               agent_uid: ctx.agent.uid,
               start: false
             })

    assert %{status: :todo, description: "A first draft."} = item
    assert inputs(item.id) == []

    assert {:ok, %{status: :todo, description: "Compare five competitors."}} =
             Issues.update(ctx.owner, item.id, %{description: "Compare five competitors."})

    assert {:error, :issue_not_found} =
             Issues.update(ctx.outsider, item.id, %{status: :started})

    assert {:ok, %{status: :working, description: nil}} =
             Issues.update(ctx.owner, item.id, %{status: :started})

    assert [%Signal{} = input] = inputs(item.id)
    assert input.data["text"] == "Pricing pages\n\nCompare five competitors."

    assert {:error, :invalid_issue} =
             Issues.update(ctx.owner, item.id, %{description: "Too late"})

    assert {:ok, _} = Issues.update(ctx.owner, item.id, %{status: :started})
    assert [_only] = inputs(item.id)
  end

  test "an Issue that a person closed before it started comes back with its request", ctx do
    assert {:ok, item} =
             Issues.create(ctx.owner, %{
               title: "Pricing pages",
               description: "Compare five competitors.",
               agent_uid: ctx.agent.uid,
               start: false
             })

    assert {:ok, %{status: :done, description: nil}} =
             Issues.update(ctx.owner, item.id, %{status: :done})

    # Nothing was sent, so reopening returns the Issue to where a person can still start it.
    assert {:ok, %{status: :todo, description: "Compare five competitors."}} =
             Issues.update(ctx.owner, item.id, %{status: :started})

    assert inputs(item.id) == []

    assert {:ok, %{status: :working}} = Issues.update(ctx.owner, item.id, %{status: :started})

    assert [%Signal{data: %{"text" => "Pricing pages\n\nCompare five competitors."}}] =
             inputs(item.id)
  end

  test "a run in the room of an Issue that waits leaves its request unsent", ctx do
    assert {:ok, item} =
             Issues.create(ctx.owner, %{
               title: "Pricing pages",
               description: "Compare five competitors.",
               agent_uid: ctx.agent.uid,
               start: false
             })

    job_id = start_job(ctx.owner, ctx.agent.uid, item.id, "Early look")
    assert {:ok, %{status: :working, runs: [_run]}} = Issues.get(ctx.owner, item.id)

    assert {:ok, _} = BackgroundAgentJobs.request_stop(job_id, %{"agent_uid" => ctx.agent.uid})

    assert {:ok, %{status: :todo, description: "Compare five competitors."}} =
             Issues.get(ctx.owner, item.id)
  end

  test "an Issue whose Agent has stopped waits for review until a person accepts it", ctx do
    assert {:ok, item} =
             Issues.create(ctx.owner, %{title: "Release notes", agent_uid: ctx.agent.uid})

    assert [%Signal{data: %{"text" => "Release notes"}}] = inputs(item.id)

    settle(item.id)
    assert {:ok, %{status: :review}} = Issues.get(ctx.owner, item.id)

    assert {:ok, %{status: :done}} = Issues.update(ctx.owner, item.id, %{status: :done})
    assert {:ok, [%{status: :done}]} = Issues.list(ctx.owner)

    assert {:ok, %{status: :review}} = Issues.update(ctx.owner, item.id, %{status: :started})
    assert [_only] = inputs(item.id)
  end

  test "an Issue follows the Background Agent Job that runs in its room", ctx do
    assert {:ok, item} =
             Issues.create(ctx.owner, %{title: "Churn report", agent_uid: ctx.agent.uid})

    settle(item.id)
    assert {:ok, %{status: :done}} = Issues.update(ctx.owner, item.id, %{status: :done})

    job_id = start_job(ctx.owner, ctx.agent.uid, item.id, "Churn analysis")

    assert {:ok, %{status: :working, runs: [run]}} = Issues.get(ctx.owner, item.id)

    assert %{kind: :background_agent_job, title: "Churn analysis", status: "queued"} = run
    assert run.id == to_string(job_id)
    assert run.agentUID == ctx.agent.uid
    assert run.stoppable

    {1, _} =
      Repo.update_all(from(job in Job, where: job.id == ^job_id),
        set: [status: :waiting_on_user]
      )

    assert {:ok, %{status: :waiting}} = Issues.get(ctx.owner, item.id)

    assert {:ok, %{job: %{status: :stopped}}} =
             BackgroundAgentJobs.request_stop(job_id, %{"agent_uid" => ctx.agent.uid})

    # The Job reopened the accepted Issue, so its result waits for review.
    assert {:ok, %{status: :review, runs: []}} = Issues.get(ctx.owner, item.id)
  end

  test "a change to an Issue tells the Pod's open tabs after it commits", ctx do
    Conversations.Events.subscribe_rooms()

    assert {:ok, item} =
             Issues.create(ctx.owner, %{
               title: "Audit the onboarding emails",
               agent_uid: ctx.agent.uid,
               start: false
             })

    assert_receive {:pod_conversations_changed}

    id = item.id
    Conversations.Events.subscribe(id)

    assert {:ok, _} = Issues.update(ctx.owner, id, %{status: :started})
    assert_receive {:conversation_event, ^id, :message}
    assert_receive {:conversation_event, ^id, :status}

    settle(id)
    assert {:ok, _} = Issues.update(ctx.owner, id, %{status: :done})
    assert_receive {:conversation_event, ^id, :status}
    refute_receive {:conversation_event, ^id, :message}
  end

  test "a Workflow that starts in an accepted Issue's room reopens it", ctx do
    assert {:ok, item} =
             Issues.create(ctx.owner, %{title: "Review the case", agent_uid: ctx.agent.uid})

    [source] = inputs(item.id)
    settle(item.id)
    assert {:ok, %{status: :done}} = Issues.update(ctx.owner, item.id, %{status: :done})

    assert {:ok, %{run: run}} =
             Ankole.Workflow.create_with_dispatch(%{
               "source_signal_id" => source.id,
               "agent_uid" => ctx.agent.uid,
               "owner_session_id" => source.session_id,
               "reply_route" => %{"conversation_id" => item.id},
               "source_tool_call_id" => "issue-workflow",
               "title" => "Review the case in parallel",
               "script" => "return await agent('Review the case');",
               "args" => %{},
               "concurrency" => 1,
               "max_agent_calls" => 1
             })

    assert {:ok, %{status: :working, runs: [%{kind: :workflow} = summary]}} =
             Issues.get(ctx.owner, item.id)

    assert summary.id == to_string(run.id)
    assert summary.title == "Review the case in parallel"
  end

  test "continuing a finished Job reopens the accepted Issue of its room", ctx do
    assert {:ok, item} =
             Issues.create(ctx.owner, %{title: "Churn report", agent_uid: ctx.agent.uid})

    job_id = start_job(ctx.owner, ctx.agent.uid, item.id, "Churn analysis")
    job = BackgroundAgentJobs.get_job(job_id)

    assert {:ok, _running} =
             Repo.transact(fn ->
               with {:ok, claimed} <-
                      Ankole.Ash.update(job, :claim_attempt, %{
                        attempts: 1,
                        started_at: DateTime.utc_now(:microsecond)
                      }) do
                 Ankole.Ash.update(claimed, :worker_report, %{
                   next_status: :running,
                   runtime_thread_id: "thread-issue-respawn"
                 })
               end
             end)

    assert {:ok, _} = BackgroundAgentJobs.request_stop(job_id, %{"agent_uid" => ctx.agent.uid})
    settle(item.id)
    assert {:ok, %{status: :done}} = Issues.update(ctx.owner, item.id, %{status: :done})

    assert {:ok, %{job: successor}} =
             BackgroundAgentJobs.respawn_with_dispatch(job_id, %{
               "source_signal_id" => Ankole.WorkFixtures.service_source(ctx.agent.uid).id,
               "agent_uid" => ctx.agent.uid,
               "owner_session_id" => Ankole.Sessions.Key.conversation(item.id),
               "source_tool_call_id" => "tool-issue-respawn",
               "message" => "Add last month's numbers.",
               "reply_route" => %{"conversation_id" => item.id}
             })

    assert {:ok, %{status: :working, runs: [%{id: run_id}]}} = Issues.get(ctx.owner, item.id)
    assert run_id == to_string(successor.id)

    assert {:ok, _} =
             BackgroundAgentJobs.request_stop(successor.id, %{"agent_uid" => ctx.agent.uid})

    assert {:ok, %{status: :review}} = Issues.get(ctx.owner, item.id)
  end

  test "a personal assistant's task room enters Work when its first Job starts", ctx do
    assistant =
      Ankole.SessionsCase.agent_fixture(%{
        type: :personal_assistant,
        owner_principal_uid: ctx.owner.principal.uid
      }).principal

    room_id = chat_room(ctx.owner, assistant.uid)

    assert {:error, :issue_not_found} = Issues.get(ctx.owner, room_id)
    assert {:ok, []} = Issues.list(ctx.owner)

    start_job(ctx.owner, assistant.uid, room_id, "Vendor report 1")

    assert {:ok, %{status: :working, tracked: true, runs: [%{title: "Vendor report 1"}]} = item} =
             Issues.get(ctx.owner, room_id)

    assert item.agent.uid == assistant.uid

    start_job(ctx.owner, assistant.uid, room_id, "Vendor report 2")

    assert {:ok, [%{id: ^room_id, tracked: true, runs: runs}]} = Issues.list(ctx.owner)
    assert Enum.map(runs, & &1.title) == ["Vendor report 2", "Vendor report 1"]
    assert {:ok, []} = Issues.list(ctx.outsider)
  end

  test "a room without an Issue appears in Work while a Background Agent Job runs in it", ctx do
    room_id = chat_room(ctx.owner, ctx.agent.uid)
    job_id = start_job(ctx.owner, ctx.agent.uid, room_id, "Vendor comparison")

    assert {:ok, [%{id: ^room_id, tracked: false, status: :working, runs: [run]} = item]} =
             Issues.list(ctx.owner)

    assert run.title == "Vendor comparison"
    assert item.agent.uid == ctx.agent.uid
    assert {:error, :issue_not_found} = Issues.get(ctx.owner, room_id)
    assert {:ok, []} = Issues.list(ctx.outsider)

    assert {:ok, _} = BackgroundAgentJobs.request_stop(job_id, %{"agent_uid" => ctx.agent.uid})
    assert {:ok, []} = Issues.list(ctx.owner)
  end

  test "a recurring rule appears for the people in the room that manages it", ctx do
    assert {:ok, item} =
             Issues.create(ctx.owner, %{title: "Weekly digest", agent_uid: ctx.agent.uid})

    assert {:ok, %{cron_schedule: rule}} =
             Ankole.Schedule.create_cron_schedule(
               %{
                 agent_uid: ctx.agent.uid,
                 owner_session_id: Ankole.Sessions.Key.conversation(item.id),
                 name: "Weekly digest",
                 schedule: %{
                   "kind" => "every",
                   "every_ms" => 3_600_000,
                   "anchor_at" => DateTime.to_iso8601(DateTime.utc_now(:microsecond)),
                   "timezone" => "UTC"
                 },
                 payload: %{"task" => "Summarize the week."},
                 delivery: %{"targets" => [%{"conversation_id" => item.id}]},
                 idempotency_key: Ecto.UUID.generate()
               },
               created_by: %{
                 "principal_uid" => to_string(Ankole.ActorRef.from_principal(ctx.owner.principal))
               }
             )

    assert {:ok, [%{kind: "cron", title: "Weekly digest", status: "active"} = row]} =
             Issues.scheduled(ctx.owner)

    assert row.id == rule.id
    assert row.conversationID == item.id
    assert row.conversationTitle == "Weekly digest"
    assert row.agentName == "Research Agent"
    assert row.dueAt == rule.next_fire_at
    assert {:ok, []} = Issues.scheduled(ctx.outsider)
  end

  test "a schedule stays hidden from a person who can no longer open its room", ctx do
    watcher = human_fixture(%{display_name: "Bob"}).principal |> actor_fixture()
    {:ok, page} = Ankole.Pod.Pages.create(ctx.owner, %{title: "Shared report"})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.principal.uid, page.id, %{
        grants: [%{principal_uid: watcher.principal.uid, role: "view"}]
      })

    room_id = Ankole.Ecto.UUIDv7.autogenerate()

    {:ok, _} =
      Ankole.ConversationsFixtures.create(ctx.owner.principal, %{
        conversation_id: room_id,
        message_id: Ankole.Ecto.UUIDv7.autogenerate(),
        agent_uid: ctx.agent.uid,
        text: "Keep this report current.",
        page_id: page.id,
        access_scope: :anchor_page
      })

    # A Page viewer who only pins the shared room stays an observer of it.
    assert {:ok, _} = Conversations.update_conversation(watcher, room_id, %{pinned: true})

    assert {:ok, %{role: :observer}} =
             Conversations.get_participant(room_id, watcher.principal.uid)

    assert {:ok, _} =
             Ankole.Schedule.create_cron_schedule(
               %{
                 agent_uid: ctx.agent.uid,
                 owner_session_id: Ankole.Sessions.Key.conversation(room_id),
                 name: "Refresh the report",
                 schedule: %{
                   "kind" => "every",
                   "every_ms" => 3_600_000,
                   "anchor_at" => DateTime.to_iso8601(DateTime.utc_now(:microsecond)),
                   "timezone" => "UTC"
                 },
                 payload: %{"task" => "Refresh the numbers."},
                 delivery: %{"targets" => [%{"conversation_id" => room_id}]},
                 idempotency_key: Ecto.UUID.generate()
               },
               created_by: %{
                 "principal_uid" => to_string(Ankole.ActorRef.from_principal(ctx.owner.principal))
               }
             )

    # The purge leaves the room to the people who joined it, and the observer never did.
    assert {:ok, _} = Ankole.Pod.Pages.Tree.trash(ctx.owner, page.id)
    assert {:ok, _} = Ankole.Pod.Pages.Tree.purge(ctx.owner, page.id)
    assert :ok = Ankole.Pod.Jobs.PurgeTree.run(%Oban.Job{args: %{"node_id" => page.id}})

    assert {:ok, [%{title: "Refresh the report", conversationID: ^room_id}]} =
             Issues.scheduled(ctx.owner)

    assert {:ok, []} = Issues.scheduled(watcher)
  end
end
