defmodule Ankole.PodChatWorkspaceMaterial do
  @moduledoc false
  alias Ankole.{BackgroundAgentJobs, Conversations, Repo}
  alias Ankole.AIGateway.{Events, ResponseCommit}
  alias Ankole.Conversations.{Native, Statement}
  alias Ankole.Sessions.{Admission, Model, Presentation, Queue, Run}

  # These are committed UI materials. They use the production domain adapters;
  # they do not represent a model or Worker run.
  def seed(owner, member, viewer, agent, parent, provider_id) do
    colleague =
      Ankole.PrincipalsFixtures.agent_fixture(%{display_name: "Browser planning Agent"}).principal

    for human <- [owner, member, viewer],
        do: Ankole.ConversationsFixtures.grant_chat(human.uid, colleague.uid)

    model = %{provider_id: provider_id, model: "fixture-model"}

    for uid <- [agent.uid, colleague.uid] do
      {:ok, _} = Ankole.AIGateway.ModelProfiles.put_model_profile(uid, "primary", model)
    end

    {:ok, _} =
      Ankole.AIGateway.ModelProfiles.put_model_profile(
        colleague.uid,
        "careful",
        Map.put(model, :description, "Browser workspace material")
      )

    actor = Ankole.PrincipalsFixtures.actor_fixture(owner.uid)

    {:ok, page} =
      Ankole.Pod.Pages.create(actor, %{title: "Chat workspace reference", parent_id: parent.id})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(owner.uid, page.id, %{
        inherit_permissions: false,
        grants: [
          %{principal_uid: owner.uid, role: "manage"},
          %{principal_uid: member.uid, role: "edit"},
          %{principal_uid: viewer.uid, role: "view"},
          %{principal_uid: agent.uid, role: "edit"},
          %{principal_uid: colleague.uid, role: "edit"}
        ]
      })

    room = create_room(actor, agent, colleague, page.id, "Review the workspace evidence.")

    markdown = """
    ## Workspace findings

    The **verified evidence** is ready. Searchable workspace result.

    | Measure | Value |
    | --- | --- |
    | Tasks | 18 |

    The estimate is $x^2$.

    ```typescript
    const total = 42
    console.log(total)
    ```

    [Reference page](ankole:page/#{page.id})
    """

    first_reply =
      complete(room.event, markdown, %{
        "duration_ms" => 4210,
        "thinking_summary" => "Check the page structure, then query the shared records.",
        "steps" => [
          %{
            "id" => "read-page",
            "tool" => "pod.pages.read",
            "title" => "Read page Workspace reference",
            "status" => "completed",
            "duration_ms" => 180,
            "input" => %{"page_id" => page.id}
          },
          %{
            "id" => "query-table",
            "tool" => "base.query",
            "title" => "Queried Tasks (18 rows)",
            "status" => "completed",
            "duration_ms" => 340,
            "output" => %{"row_count" => 18}
          }
        ]
      })

    {:ok, followup} =
      Repo.transact_top_level(fn ->
        Native.post_in_tx(actor, room.id, %{
          message_id: Ankole.Ecto.UUIDv7.autogenerate(),
          text: "Ask the planning colleague for a second view.",
          target_agent_uid: colleague.uid
        })
      end)

    second_reply =
      complete(followup.event, "A second colleague confirmed the workspace result.", %{
        "duration_ms" => 900,
        "steps" => [
          %{
            "id" => "check-plan",
            "tool" => "pod.pages.read",
            "title" => "Read the shared plan",
            "status" => "completed",
            "duration_ms" => 120
          }
        ]
      })

    for index <- 3..4 do
      {:ok, checkpoint} =
        Repo.transact_top_level(fn ->
          Native.post_in_tx(actor, room.id, %{
            message_id: Ankole.Ecto.UUIDv7.autogenerate(),
            text: "Workspace review checkpoint #{index}",
            target_agent_uid: agent.uid
          })
        end)

      complete(checkpoint.event, "Review checkpoint #{index} is complete.", %{
        "duration_ms" => 500,
        "steps" => []
      })
    end

    clarify =
      create_room(actor, agent, colleague, page.id, "Choose a report destination.", [member.uid])

    decision = decision_material(clarify)

    reference_decision =
      create_room(actor, agent, colleague, page.id, "Review this referenced answer.")

    decision_material(reference_decision)

    {:ok, _} =
      Conversations.manage_participants(actor, reference_decision.id, %{
        agent_uid: agent.uid,
        may_intervene: false
      })

    for index <- 1..501 do
      {:ok, _} =
        Repo.transact_top_level(fn ->
          Native.post_in_tx(actor, reference_decision.id, %{
            message_id: Ankole.Ecto.UUIDv7.autogenerate(),
            text: "Room discussion note #{index}."
          })
        end)
    end

    interleaved = interleaved_material(actor, member, agent, colleague, page.id)

    queued = create_room(actor, agent, colleague, page.id, "Run the long workspace analysis.")

    {:ok, run} =
      Admission.admit(%{agent_uid: agent.uid, session_id: queued.event.session_id}, queued.event)

    {:ok, {:preparing, _}} = Model.prepare(run)

    attachment_path =
      Path.join(System.tmp_dir!(), "ankole-chat-queue-#{Ankole.Ecto.UUIDv7.autogenerate()}.txt")

    File.write!(attachment_path, "Queue attachment evidence.\n")

    receipt =
      try do
        {:ok, upload} =
          Ankole.Conversations.Attachments.Native.upload(
            actor,
            Ankole.Ecto.UUIDv7.autogenerate(),
            "workspace-queue-note.txt",
            {:file, attachment_path},
            "text/plain"
          )

        upload.receipt
      after
        File.rm!(attachment_path)
      end

    queue_ids =
      for text <- ["Queue alpha", "Queue beta", "Queue gamma"] do
        message_id = Ankole.Ecto.UUIDv7.autogenerate()

        {:ok, _} =
          Repo.transact_top_level(fn ->
            Native.post_in_tx(actor, queued.id, %{
              message_id: message_id,
              text: text,
              target_agent_uid: agent.uid,
              delivery_mode: "queue",
              attachments: if(text == "Queue beta", do: [receipt], else: [])
            })
          end)

        message_id
      end

    execution = execution_material(actor, agent, colleague, page.id)
    live = live_material(actor, agent, colleague, page.id)

    %{
      page_id: page.id,
      conversation_id: room.id,
      first_reply_id: first_reply.id,
      second_reply_id: second_reply.id,
      colleague_uid: colleague.uid,
      clarify_conversation_id: clarify.id,
      clarify_message_id: hd(decision.messages).id,
      reference_decision_conversation_id: reference_decision.id,
      interleaved_conversation_id: interleaved.id,
      interleaved_question_id: interleaved.question_id,
      interleaved_reply_id: interleaved.reply_id,
      queue_conversation_id: queued.id,
      queue_message_ids: queue_ids,
      execution_conversation_id: execution.id,
      linked_job_id: execution.job_id,
      live_conversation_id: live.id,
      live_trigger_path: live.trigger_path,
      live_agent_uids: live.agent_uids
    }
  end

  defp decision_material(clarify) do
    prompt = %{
      "interaction_id" => "clarify:workspace-destination",
      "body" => "Where should the workspace report go?",
      "choices" => [
        %{
          "id" => "choice-1",
          "label" => "Publish to the shared page",
          "value" => "Publish to the shared page"
        },
        %{
          "id" => "choice-2",
          "label" => "Keep a private draft",
          "value" => "Keep a private draft"
        }
      ],
      "free_input" => true,
      "version" => 1,
      "control_id" => "clarify-choice"
    }

    {:ok, decision} =
      Repo.transact_top_level(fn ->
        with :ok <- Queue.lock_session_in_tx(clarify.event.agent_uid, clarify.event.session_id),
             {:ok, posted} <-
               Presentation.post_in_tx(clarify.event, %Statement{
                 signal: clarify.event,
                 now: DateTime.utc_now(:microsecond),
                 completion: %{
                   final_text: nil,
                   attachments: [],
                   clarify_prompt: %{"interactive_output" => prompt},
                   execution: %{"duration_ms" => 620, "steps" => []}
                 }
               }),
             {:ok, _} <-
               Queue.mark_event_completed_in_tx(clarify.event, DateTime.utc_now(:microsecond)),
             do: {:ok, posted}
      end)

    decision
  end

  defp interleaved_material(actor, member, agent, colleague, page_id) do
    room =
      create_room(actor, agent, colleague, page_id, "Review the access decision.", [member.uid])

    {:ok, other} =
      Repo.transact_top_level(fn ->
        Native.post_in_tx(Ankole.PrincipalsFixtures.actor_fixture(member.uid), room.id, %{
          message_id: Ankole.Ecto.UUIDv7.autogenerate(),
          text: "Prepare the launch checklist.",
          target_agent_uid: colleague.uid
        })
      end)

    complete(other.event, "The launch checklist is ready.", %{"steps" => []})
    reply = complete(room.event, "The access review has one unresolved owner.", %{"steps" => []})

    for index <- 3..4 do
      speaker =
        if index == 4, do: Ankole.PrincipalsFixtures.actor_fixture(member.uid), else: actor

      {:ok, checkpoint} =
        Repo.transact_top_level(fn ->
          Native.post_in_tx(speaker, room.id, %{
            message_id: Ankole.Ecto.UUIDv7.autogenerate(),
            text: "Interleaved follow-up #{index}",
            target_agent_uid: agent.uid
          })
        end)

      complete(checkpoint.event, "Interleaved follow-up #{index} is complete.", %{"steps" => []})
    end

    %{id: room.id, question_id: room.event.message_id, reply_id: reply.id}
  end

  defp execution_material(actor, agent, colleague, page_id) do
    room = create_room(actor, agent, colleague, page_id, "Review recorded background execution.")

    {:ok, %{job: job}} =
      BackgroundAgentJobs.create_with_dispatch(%{
        "source_signal_id" => room.event.id,
        "agent_uid" => agent.uid,
        "owner_session_id" => room.event.session_id,
        "source_tool_call_id" => "workspace-recorded-job",
        "title" => "Recorded workspace execution",
        "task" => "Review the recorded execution material.",
        "model_profile" => "careful",
        "reply_route" => %{"conversation_id" => room.id}
      })

    run = prepare(room.event)

    {:ok, _} =
      Repo.transact(fn ->
        BackgroundAgentJobs.Lifecycle.claim_attempt_in_tx(job.id, agent.uid, 1, run.spec, 10)
      end)

    {:ok, %{job: job}} =
      BackgroundAgentJobs.commit_status_with_wakeup(job.id, agent.uid, %{
        "status" => "running",
        "runtime_thread_id" => "workspace-recorded-job"
      })

    now = DateTime.utc_now(:microsecond) |> DateTime.to_iso8601()

    items = [
      %{
        "type" => "userMessage",
        "id" => "recorded-private-context",
        "content" => [%{"type" => "text", "text" => "Recorded private model context"}]
      }
      | for index <- 1..45 do
          %{
            "type" => "agentMessage",
            "id" => "recorded-step-#{index}",
            "text" => "Recorded execution step #{index}."
          }
        end
    ]

    {:ok, _} =
      Repo.transact(fn ->
        BackgroundAgentJobs.Turns.upsert_from_worker_in_tx(job, %{
          "attempt" => 1,
          "runtime_thread_id" => "workspace-recorded-job",
          "runtime_turn_id" => "recorded-log-turn",
          "kind" => "agent",
          "status" => "completed",
          "revision" => 0,
          "started_at" => now,
          "completed_at" => now,
          "trajectory" => %{"format" => "ankole_chatml", "version" => 1},
          "turn_items" =>
            Enum.with_index(items, fn item, index ->
              %{"position" => index, "item_key" => item["id"], "item" => item}
            end)
        })
      end)

    {:ok, response} =
      run
      |> open_response()
      |> ResponseCommit.commit_complete([
        %{
          "type" => "output_text",
          "text" => "The recorded background execution is available below."
        }
      ])

    {:ok, _} = Run.finalize(%{run | model_response: response, anchor: response.id})
    %{id: room.id, job_id: to_string(job.id)}
  end

  defp live_material(actor, agent, colleague, page_id) do
    room =
      create_room(actor, agent, colleague, page_id, "Compare the recorded workspace evidence.")

    complete(room.event, "Recorded evidence is ready for the two colleagues.", %{
      "duration_ms" => 520,
      "steps" => [
        %{
          "id" => "recorded-read",
          "tool" => "pod.pages.read",
          "title" => "Read the recorded reference",
          "status" => "completed"
        },
        %{
          "id" => "recorded-command",
          "tool" => "command",
          "title" => "Check the recorded workspace",
          "status" => "completed",
          "input" => "{\"command\":\"git status --short\"}",
          "output" => "exit_code=0\nduration=120ms\n M report.md"
        }
      ]
    })

    {:ok, posted} =
      Repo.transact_top_level(fn ->
        Native.post_in_tx(actor, room.id, %{
          message_id: Ankole.Ecto.UUIDv7.autogenerate(),
          text: "Review the recorded findings together.",
          target_agent_uid: agent.uid,
          mentions: [%{"type" => "agent", "uid" => colleague.uid}]
        })
      end)

    responses = Enum.map(posted.events, &(&1 |> prepare() |> open_response()))
    trigger_path = System.fetch_env!("POD_BROWSER_STATE_PATH") <> ".live"
    File.rm(trigger_path)
    System.at_exit(fn _ -> File.rm(trigger_path) end)
    tenant_id = Repo.tenant_id!()

    spawn_link(fn ->
      Repo.put_tenant_id(tenant_id)
      await_live_trigger(trigger_path, responses)
    end)

    %{id: room.id, trigger_path: trigger_path, agent_uids: Enum.map(responses, & &1.subject_uid)}
  end

  # This one-shot fixture control emits recorded content through the production
  # Gateway publisher and Pod SSE adapter. It is not model or Worker execution.
  defp await_live_trigger(path, responses) do
    if File.exists?(path) do
      File.rm!(path)

      for {response, index} <- Enum.with_index(responses, 1) do
        :ok = Events.publish(response, :response_started, %{})

        reasoning =
          Enum.map_join(1..18, "\n\n", fn line ->
            "Recorded colleague #{index} reasoning #{line}: compare the source, check the result, then explain the evidence."
          end)

        :ok = Events.publish(response, :reasoning_delta, %{text: reasoning})

        :ok =
          Events.publish(response, :output_text_delta, %{
            text: "Recorded colleague #{index} answer: "
          })
      end

      Process.sleep(150)

      for {response, index} <- Enum.with_index(responses, 1) do
        :ok =
          Events.publish(response, :output_text_delta, %{
            text: "independent workspace result #{index}."
          })
      end
    else
      Process.sleep(100)
      await_live_trigger(path, responses)
    end
  end

  defp prepare(event) do
    {:ok, run} =
      Admission.admit(%{agent_uid: event.agent_uid, session_id: event.session_id}, event)

    {:ok, {:preparing, run}} = Model.prepare(run)
    run
  end

  defp open_response(run) do
    {:ok, response} =
      Ankole.AIGatewayCase.start_response_run(%{
        subject_uid: run.agent_uid,
        conversation_id: run.conversation.id,
        round_state: run,
        metadata: %{"request_metadata" => Run.metadata(run)}
      })

    response
  end

  defp create_room(actor, agent, colleague, page_id, text, invited \\ []) do
    {:ok, room} =
      Repo.transact_top_level(fn ->
        Conversations.create_in_tx(actor, %{
          conversation_id: Ankole.Ecto.UUIDv7.autogenerate(),
          message_id: Ankole.Ecto.UUIDv7.autogenerate(),
          agent_uids: [agent.uid, colleague.uid],
          participant_uids: invited,
          target_agent_uid: agent.uid,
          page_id: page_id,
          text: text,
          model_profile: "careful"
        })
      end)

    room
  end

  defp complete(event, text, execution) do
    {:ok, posted} =
      Repo.transact_top_level(fn ->
        with :ok <- Queue.lock_session_in_tx(event.agent_uid, event.session_id),
             {:ok, posted} <-
               Presentation.post_in_tx(event, %Statement{
                 signal: event,
                 now: DateTime.utc_now(:microsecond),
                 completion: %{
                   final_text: text,
                   clarify_prompt: nil,
                   attachments: [],
                   execution: execution
                 }
               }),
             {:ok, _} <- Queue.mark_event_completed_in_tx(event, DateTime.utc_now(:microsecond)),
             do: {:ok, posted}
      end)

    hd(posted.messages)
  end
end
