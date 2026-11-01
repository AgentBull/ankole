defmodule Ankole.Sessions.WakeRecycleTest do
  use Ankole.SessionsCase

  alias Ankole.AIGateway.ResponseCommit
  alias Ankole.AIGateway.Schemas.Conversation, as: AIConversation
  alias Ankole.Conversations
  alias Ankole.ConversationsFixtures
  alias Ankole.Conversations.Delivery.PreviewStates
  alias Ankole.Kernel, as: NativeKernel
  alias Ankole.Pod.Pages
  alias Ankole.Sessions.Admission
  alias Ankole.Sessions.Model
  alias Ankole.Sessions.ModelHistory
  alias Ankole.Sessions.Run
  alias Ankole.Sessions.Tools
  alias Ankole.Signals.Signal
  alias Ankole.Workflow

  setup {Ankole.SessionsCase, :use_mock_signal_provider_plugin}

  defp key(event), do: %{agent_uid: event.agent_uid, session_id: event.session_id}

  defp commit_turn_with_usage!(run, text, total_tokens, output_items \\ nil) do
    ai_run = start_aigateway_run_for_turn!(run, [])

    items =
      output_items ||
        [
          %{
            "type" => "message",
            "role" => "assistant",
            "content" => [%{"type" => "output_text", "text" => text}]
          }
        ]

    {:ok, committed} =
      ResponseCommit.commit_complete(ai_run, items, %{
        "usage" => %{
          "input_tokens" => max(total_tokens - 500, 1),
          "output_tokens" => 500,
          "total_tokens" => total_tokens
        }
      })

    assert {:ok, %{status: status}} =
             commit_turn_completion(run, "resp_#{committed.id}", :loop_finished)

    assert status in [:completed, :turn_completed]
    committed
  end

  defp extract_briefing_text(request_input) when is_list(request_input) do
    request_input
    |> Enum.flat_map(fn
      %{"content" => parts} when is_list(parts) ->
        Enum.map(parts, &Map.get(&1, "text", ""))

      _ ->
        []
    end)
    |> Enum.find(&String.contains?(&1, "<wake-briefing"))
  end

  describe "cold-wake conversation rotation and deterministic wake briefing" do
    test "rotates >= 1h cold >= 128k conversation once, injects <= 8k wake briefing with live Drive reread + offline workspace pointer + sensitive redaction, and is retry-idempotent" do
      %{principal: human} = Ankole.PrincipalsFixtures.human_fixture()
      %{principal: agent} = agent_fixture(%{owner_principal_uid: human.uid})
      ConversationsFixtures.grant_chat(human.uid, agent.uid)

      actor = Ankole.AuthZ.Actor.new(human)
      {:ok, page} = Pages.create(actor, %{title: "Launch Runbook", private_owner_uid: human.uid})
      page_id = page.id

      assert {:ok, _} =
               Ankole.Pod.Documents.write(
                 actor,
                 page_id,
                 page.revision,
                 "<page><p>Deploy checklist v2 live content</p></page>"
               )

      assert {:ok, _} =
               Ankole.Pod.PagesFixtures.set_sharing(human.uid, page_id, %{
                 grants: [%{principal_uid: agent.uid, role: "view"}]
               })

      conversation_id = Ecto.UUID.generate()
      first_msg_id = Ecto.UUID.generate()

      assert {:ok, detail} =
               ConversationsFixtures.create(human.uid, %{
                 conversation_id: conversation_id,
                 message_id: first_msg_id,
                 agent_uid: agent.uid,
                 text: "Review the launch runbook and staging config."
               })

      first_signal = Repo.get_by!(Signal, message_id: first_msg_id)
      t0 = DateTime.utc_now(:microsecond)

      assert {:ok, first_run} = Admission.admit(key(first_signal), first_signal, now: t0)
      predecessor = first_run.conversation

      assert ModelHistory.cli_context_id(agent.uid, predecessor) ==
               "#{predecessor.id}:cmp:root"

      output_items = [
        %{
          "type" => "function_call",
          "call_id" => "call-rel-read",
          "name" => "read_file",
          "arguments" => Jason.encode!(%{"path" => "notes/session_memo.md"})
        },
        %{
          "type" => "function_call_output",
          "call_id" => "call-rel-read",
          "output" => "session memo v1"
        },
        %{
          "type" => "function_call",
          "call_id" => "call-secret-read",
          "name" => "read_file",
          "arguments" => Jason.encode!(%{"path" => ".env.production"})
        },
        %{
          "type" => "function_call_output",
          "call_id" => "call-secret-read",
          "output" => "redacted"
        },
        %{
          "type" => "function_call",
          "call_id" => "call-doc-read",
          "name" => "pages.read",
          "arguments" => Jason.encode!(%{"page_id" => page_id})
        },
        %{
          "type" => "function_call_output",
          "call_id" => "call-doc-read",
          "output" => %{"ok" => true}
        },
        %{
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "output_text", "text" => "Initial check complete."}]
        }
      ]

      commit_turn_with_usage!(first_run, "Initial check complete.", 140_000, output_items)

      followup_id = Ecto.UUID.generate()

      assert {:ok, _} =
               ConversationsFixtures.post(human.uid, detail.conversation.id, %{
                 message_id: followup_id,
                 text: "Now verify the updated checklist.",
                 reply_to_message_id: first_msg_id
               })

      followup_signal = Repo.get_by!(Signal, message_id: followup_id)
      wake_at = DateTime.add(DateTime.utc_now(:microsecond), 3_900, :second)

      assert {:ok, recycled_run} =
               Admission.admit(key(followup_signal), followup_signal, now: wake_at)

      successor = recycled_run.conversation
      assert successor.id != predecessor.id

      closed_predecessor = Repo.get!(AIConversation, predecessor.id)
      assert closed_predecessor.ended_at != nil

      assert successor.metadata["wake_briefing"]["previous_conversation_id"] == predecessor.id
      assert successor.metadata["wake_briefing"]["reason"] == "cold_prompt_cache_large_context"

      # Crash/retry idempotency: admitting the same Signal again when last_attempt_at is set
      # must NOT close the successor conversation or rotate a second time.
      reloaded_signal = Repo.get!(Signal, followup_signal.id)
      assert reloaded_signal.last_attempt_at != nil

      assert {:ok, retried_run} =
               Admission.admit(
                 key(reloaded_signal),
                 reloaded_signal,
                 now: DateTime.add(wake_at, 7_200, :second)
               )

      assert retried_run.conversation.id == successor.id
      assert Repo.get!(AIConversation, successor.id).ended_at == nil

      # Queue a second unadmitted follow-up message behind `followup_signal` and ensure it is excluded from Turn 1's briefing
      queued_later_id = Ecto.UUID.generate()

      assert {:ok, _} =
               ConversationsFixtures.post(human.uid, detail.conversation.id, %{
                 message_id: queued_later_id,
                 text: "UNADMITTED_QUEUED_FOLLOWUP_SENTINEL"
               })

      # Build the Turn 1 model request and inspect the injected <wake-briefing>
      model_req = Model.request(recycled_run)
      briefing = extract_briefing_text(model_req["input"])
      assert is_binary(briefing)

      assert NativeKernel.estimate_o200k_base_tokens(briefing) <= 8_000
      refute briefing =~ ~r/session (was )?reset/i
      assert briefing =~ "<recent-messages>"
      assert briefing =~ "Review the launch runbook"
      refute briefing =~ "UNADMITTED_QUEUED_FOLLOWUP_SENTINEL"
      assert briefing =~ "<recent-actions>"
      assert briefing =~ "<objects-in-play>"
      assert briefing =~ "Deploy checklist v2 live content"

      assert briefing =~
               ~s(path="/workspace/sessions/#{recycled_run.workspace_id}/notes/session_memo.md" source="workspace" status="worker_offline_not_reread")

      assert briefing =~
               ~s(path="/workspace/sessions/#{recycled_run.workspace_id}/.env.production" source="workspace" status="redacted_sensitive_path")

      assert model_req["metadata"]["wake_briefing_injected"] == true
      assert model_req["metadata"]["conversation_read"]["max_seq"] >= 1
    end

    test "online workspace rereads keep split UTF-8 text and distinguish binary and file errors" do
      %{principal: human} = Ankole.PrincipalsFixtures.human_fixture()
      %{principal: agent} = agent_fixture(%{owner_principal_uid: human.uid})
      ConversationsFixtures.grant_chat(human.uid, agent.uid)
      route = "wake-prefix-#{agent.uid}"
      assert {:ok, _worker} = admit_worker(route, %{worker_id: agent.uid})

      content =
        "UTF8_PREFIX " <> String.duplicate("a", 16_383 - byte_size("UTF8_PREFIX ")) <> "中尾部"

      Ankole.WorkerFilesFake.start!(route,
        on_read: fn path ->
          cond do
            String.ends_with?(path, "text.txt") -> {:ok, content}
            String.ends_with?(path, "binary.bin") -> {:ok, "before" <> <<255>> <> "after"}
            String.ends_with?(path, "large.txt") -> {:error, {"file_too_large", "too large"}}
            true -> {:error, {"file_not_found", "missing"}}
          end
        end
      )

      for {path, status} <- [
            {"text.txt", "live_reread"},
            {"binary.bin", "binary_not_inlined"},
            {"large.txt", "file_too_large"},
            {"missing.txt", "missing"}
          ] do
        message_id = Ecto.UUID.generate()

        assert {:ok, detail} =
                 ConversationsFixtures.create(human.uid, %{
                   conversation_id: Ecto.UUID.generate(),
                   message_id: message_id,
                   agent_uid: agent.uid,
                   text: "Inspect the workspace file."
                 })

        signal = Repo.get_by!(Signal, message_id: message_id)
        assert {:ok, first} = Admission.admit(key(signal), signal)

        commit_turn_with_usage!(first, "Inspected.", 140_000, [
          %{
            "type" => "function_call",
            "call_id" => "read-prefix",
            "name" => "read_file",
            "arguments" => Jason.encode!(%{"path" => path})
          },
          %{
            "type" => "function_call_output",
            "call_id" => "read-prefix",
            "output" => "inspected"
          },
          %{
            "type" => "message",
            "role" => "assistant",
            "content" => [%{"type" => "output_text", "text" => "Inspected."}]
          }
        ])

        next_id = Ecto.UUID.generate()

        assert {:ok, _} =
                 ConversationsFixtures.post(human.uid, detail.conversation.id, %{
                   message_id: next_id,
                   text: "Check the file again."
                 })

        followup = Repo.get_by!(Signal, message_id: next_id)

        assert {:ok, run} =
                 Admission.admit(key(followup), followup,
                   now: DateTime.add(DateTime.utc_now(:microsecond), 3_900, :second)
                 )

        briefing = run |> Model.request() |> Map.fetch!("input") |> extract_briefing_text()
        assert briefing =~ ~s(source="workspace" status="#{status}")
        refute briefing =~ "worker_offline_not_reread"
        if path == "text.txt", do: assert(briefing =~ "UTF8_PREFIX")
      end
    end

    test "preserves prepared ActionCards across cold-wake rotation while superseding pending clarify cards" do
      %{principal: human} = Ankole.PrincipalsFixtures.human_fixture()
      %{principal: agent} = agent_fixture(%{owner_principal_uid: human.uid})
      ConversationsFixtures.grant_chat(human.uid, agent.uid)

      actor = Ankole.AuthZ.Actor.new(human)
      {:ok, page} = Pages.create(actor, %{title: "Shared Roadmap", private_owner_uid: human.uid})
      page_id = page.id

      assert {:ok, _} =
               Ankole.Pod.PagesFixtures.set_sharing(human.uid, page_id, %{
                 grants: [%{principal_uid: agent.uid, role: "view"}]
               })

      conversation_id = Ecto.UUID.generate()
      first_msg_id = Ecto.UUID.generate()

      assert {:ok, detail} =
               ConversationsFixtures.create(human.uid, %{
                 conversation_id: conversation_id,
                 message_id: first_msg_id,
                 agent_uid: agent.uid,
                 text: "Share the roadmap and ask me about scope."
               })

      first_signal = Repo.get_by!(Signal, message_id: first_msg_id)
      assert {:ok, first_run} = Admission.admit(key(first_signal), first_signal, now: @base_time)
      assert {:ok, {:preparing, first_run}} = Model.prepare(first_run)

      tool_args = %{
        "action_kind" => "pod.page.set_sharing",
        "node_id" => page_id,
        "summary" => "Update Shared Roadmap grants",
        "grants" => [%{principal_uid: agent.uid, role: "view"}]
      }

      call = %{
        "type" => "function_call",
        "call_id" => "call-action-card-1",
        "name" => "propose_action_card",
        "arguments" => Jason.encode!(tool_args)
      }

      ai_run = start_aigateway_run_for_turn!(first_run, [])
      {:ok, ai_run} = ResponseCommit.commit_complete(ai_run, [call])

      first_run_with_resp = %{
        first_run
        | model_response: ai_run,
          calls: [call],
          round_calls: [call],
          anchor: ai_run.id
      }

      assert {:ok, tool, parsed_args} = Tools.prepare(first_run_with_resp, call)
      exec_result = Tools.execute(first_run_with_resp, call, tool, parsed_args)
      refute exec_result.is_error
      card_id = exec_result.details["card_id"]

      assert {:ok, _journal} =
               Run.record_round(%{
                 first_run_with_resp
                 | results: %{"call-action-card-1" => exec_result}
               })

      assert {:ok, {_state, restored_run}} = Run.restore(first_run)
      assert {:ok, _finalized} = Run.finalize(restored_run)

      # Turn 2 in the same conversation emits a pending `clarify` card and crosses 128k tokens
      second_msg_id = Ecto.UUID.generate()

      assert {:ok, _} =
               ConversationsFixtures.post(human.uid, detail.conversation.id, %{
                 message_id: second_msg_id,
                 text: "Also ask me about Q4 scope."
               })

      second_signal = Repo.get_by!(Signal, message_id: second_msg_id)

      assert {:ok, second_run} =
               Admission.admit(
                 key(second_signal),
                 second_signal,
                 now: DateTime.add(@base_time, 10, :second)
               )

      assert second_run.conversation.id == first_run.conversation.id

      clarify_items = [
        %{
          "type" => "function_call",
          "call_id" => "call-clarify-1",
          "name" => "clarify",
          "arguments" => "{}"
        },
        %{
          "type" => "function_call_output",
          "call_id" => "call-clarify-1",
          "output" => %{
            "tool" => "clarify",
            "ok" => true,
            "question" => "Include Q4?",
            "choices" => [%{"label" => "Yes"}, %{"label" => "No"}]
          }
        }
      ]

      commit_turn_with_usage!(second_run, "", 135_500, clarify_items)

      card_checkpoint_before =
        PreviewStates.get(Repo.get!(Signal, first_signal.id)).checkpoint["interactions"]

      clarify_checkpoint_before =
        PreviewStates.get(Repo.get!(Signal, second_signal.id)).checkpoint["interactions"]

      assert card_checkpoint_before["action_card:#{card_id}"]["state"] == "pending"
      assert clarify_checkpoint_before["clarify:call-clarify-1"]["state"] == "pending"

      next_msg_id = Ecto.UUID.generate()

      assert {:ok, _} =
               ConversationsFixtures.post(human.uid, detail.conversation.id, %{
                 message_id: next_msg_id,
                 text: "New topic after lunch."
               })

      next_signal = Repo.get_by!(Signal, message_id: next_msg_id)
      wake_at = DateTime.add(DateTime.utc_now(:microsecond), 4_000, :second)

      assert {:ok, next_run} = Admission.admit(key(next_signal), next_signal, now: wake_at)
      assert next_run.conversation.id != first_run.conversation.id

      card_checkpoint_after =
        PreviewStates.get(Repo.get!(Signal, first_signal.id)).checkpoint["interactions"]

      clarify_checkpoint_after =
        PreviewStates.get(Repo.get!(Signal, second_signal.id)).checkpoint["interactions"]

      assert clarify_checkpoint_after["clarify:call-clarify-1"]["state"] == "superseded"
      assert card_checkpoint_after["action_card:#{card_id}"]["state"] == "pending"

      assert {:ok, _detail} =
               Conversations.resolve_action_card(actor, detail.conversation.id, card_id, :confirm)
    end

    test "answering a pending clarification card via native answer_interaction is exempt from cold-wake rotation" do
      %{principal: human} = Ankole.PrincipalsFixtures.human_fixture()
      %{principal: agent} = agent_fixture(%{owner_principal_uid: human.uid})
      ConversationsFixtures.grant_chat(human.uid, agent.uid)

      conversation_id = Ecto.UUID.generate()
      first_msg_id = Ecto.UUID.generate()

      assert {:ok, detail} =
               ConversationsFixtures.create(human.uid, %{
                 conversation_id: conversation_id,
                 message_id: first_msg_id,
                 agent_uid: agent.uid,
                 text: "Ask me a question."
               })

      first_signal = Repo.get_by!(Signal, message_id: first_msg_id)
      assert {:ok, first_run} = Admission.admit(key(first_signal), first_signal, now: @base_time)

      output_items = [
        %{
          "type" => "function_call",
          "call_id" => "call-clarify-native",
          "name" => "clarify",
          "arguments" => "{}"
        },
        %{
          "type" => "function_call_output",
          "call_id" => "call-clarify-native",
          "output" => %{
            "tool" => "clarify",
            "ok" => true,
            "question" => "Which region?",
            "choices" => [%{"label" => "APAC"}, %{"label" => "EMEA"}]
          }
        }
      ]

      commit_turn_with_usage!(first_run, "", 145_000, output_items)

      checkpoint = PreviewStates.get(Repo.get!(Signal, first_signal.id)).checkpoint
      first_choice_id = hd(checkpoint["presentation"]["actions"])["selected_option_id"]
      native_interaction_id = "#{first_signal.id}:clarify:call-clarify-native"

      assert {:ok, _} =
               Conversations.answer_interaction(
                 Ankole.AuthZ.Actor.new(human),
                 detail.conversation.id,
                 native_interaction_id,
                 %{"choice_id" => first_choice_id}
               )

      answer_signal =
        Repo.one!(
          from(s in Signal,
            where: s.conversation_id == ^detail.conversation.id and s.id != ^first_signal.id
          )
        )

      assert answer_signal.data["answered_interaction_id"] == native_interaction_id

      wake_at = DateTime.add(DateTime.utc_now(:microsecond), 7_200, :second)
      assert {:ok, answer_run} = Admission.admit(key(answer_signal), answer_signal, now: wake_at)

      assert answer_run.conversation.id == first_run.conversation.id
    end

    test "live owned Workflow run blocks cold-wake rotation, while 72h IM idle gap rotates small contexts" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-rich-provider")

      assert {:ok, %{signal: s1}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   source_event_id: "im-72h-1",
                   provider_conversation_id: "lark:chat:im-72h",
                   provider_message_id: "msg-im-72h-1",
                   text: "Quick ping.",
                   explicit: true
                 }),
                 now: @base_time
               )

      assert {:ok, r1} = Admission.admit(key(s1), s1, now: @base_time)

      commit_turn_with_usage!(r1, "Pong!", 4_000, [
        %{
          "type" => "function_call",
          "call_id" => "call-im-drive",
          "name" => "command",
          "arguments" =>
            Jason.encode!(%{
              "command" =>
                "ankole-files put /tmp/local.md reports/q3-summary.md && ankole-files get --output /tmp/out.md reports/q2-summary.md"
            })
        },
        %{
          "type" => "function_call_output",
          "call_id" => "call-im-drive",
          "output" => %{"ok" => true}
        },
        %{
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "output_text", "text" => "Pong!"}]
        }
      ])

      t_73h = DateTime.add(DateTime.utc_now(:microsecond), 73 * 3_600, :second)

      assert {:ok, %{signal: s2}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   source_event_id: "im-72h-2",
                   provider_conversation_id: "lark:chat:im-72h",
                   provider_message_id: "msg-im-72h-2",
                   text: "Morning update?",
                   explicit: true
                 }),
                 now: t_73h
               )

      assert {:ok, r2} = Admission.admit(key(s2), s2, now: t_73h)
      assert r2.conversation.id != r1.conversation.id
      assert r2.conversation.metadata["wake_briefing"]["reason"] == "im_extended_idle"
      assert is_map(r2.conversation.metadata["origin"])

      im_briefing = extract_briefing_text(Model.request(r2)["input"])

      [_, objects_section] =
        Regex.run(~r/<objects-in-play>([\s\S]*?)<\/objects-in-play>/, im_briefing)

      assert objects_section =~
               ~s(path="drive:/reports/q3-summary.md" source="drive" status="missing")

      assert objects_section =~
               ~s(path="drive:/reports/q2-summary.md" source="drive" status="missing")

      refute objects_section =~ "/tmp/local.md"
      refute objects_section =~ "/tmp/out.md"

      commit_turn_with_usage!(r2, "All green.", 150_000)

      assert {:ok, %{run: wf_run}} =
               Workflow.create_with_dispatch(%{
                 "source_signal_id" => s2.id,
                 "agent_uid" => agent.uid,
                 "owner_session_id" => s2.session_id,
                 "reply_route" => %{"conversation_id" => s2.conversation_id},
                 "source_tool_call_id" => "call-wf-block-1",
                 "title" => "Nightly audit",
                 "script" => "export default async () => ({ ok: true })",
                 "args" => %{},
                 "model_profile" => "primary",
                 "concurrency" => 1,
                 "max_agent_calls" => 4
               })

      assert wf_run.status == :running

      t_75h = DateTime.add(t_73h, 7_200, :second)

      assert {:ok, %{signal: s3}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   source_event_id: "im-72h-3",
                   provider_conversation_id: "lark:chat:im-72h",
                   provider_message_id: "msg-im-72h-3",
                   text: "Is the audit still running?",
                   explicit: true
                 }),
                 now: t_75h
               )

      assert {:ok, r3} = Admission.admit(key(s3), s3, now: t_75h)
      assert r3.conversation.id == r2.conversation.id
    end
  end
end
