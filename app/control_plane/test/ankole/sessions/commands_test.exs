defmodule Ankole.Sessions.CommandsTest do
  alias Ankole.AIGateway.ResponseCommit
  alias Ankole.AIGateway.CompactionPolicy
  use Ankole.SessionsCase
  alias Ankole.Sessions.Admission
  alias Ankole.Sessions.Commands
  alias Ankole.Sessions.Model
  alias Ankole.Sessions.Run
  alias Ankole.AIGateway.CompactionArtifacts
  alias Ankole.AIGateway.Schemas.CompactionArtifact
  alias Ankole.AgentWorkers.AgentWorker

  setup {Ankole.SessionsCase, :use_mock_signal_provider_plugin}

  test "an idle steer prepares its instructions without a Worker" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)

    {:ok, %{signal: event}} =
      emit_entry(agent.uid, "bot", group_entry(%{text: "/steer Change course", explicit: true}),
        now: @base_time
      )

    assert Commands.route(event) == :run
    assert {:ok, run} = Admission.admit(event, event)
    assert {:ok, {:preparing, prepared}} = Model.prepare(run)
    text = Ankole.JSON.encode!(prepared.input)
    assert text =~ "Change course"
    refute text =~ "/steer"
    assert Repo.get!(AgentWorker, agent.uid).state == "absent"
  end

  test "a final reply leaves an unread steer open for the next run" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)

    {:ok, %{signal: input}} =
      emit_entry(agent.uid, "bot", group_entry(%{text: "First request", explicit: true}),
        now: @base_time
      )

    {:ok, run} = Admission.admit(input, input)

    {:ok, model} =
      start_response_run(%{
        subject_uid: run.agent_uid,
        conversation_id: run.conversation.id,
        round_state: run,
        metadata: %{"request_metadata" => Ankole.Sessions.Run.metadata(run)}
      })

    {:ok, final} =
      ResponseCommit.commit_complete(model, [
        %{
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "output_text", "text" => "The first request is complete."}]
        }
      ])

    {:ok, %{signal: steer}} =
      emit_entry(
        agent.uid,
        "bot",
        group_entry(%{text: "/steer Next requirement", explicit: true}),
        now: DateTime.add(@base_time, 1)
      )

    assert {:ok, %{posted: %{intents: [box]}}} = Run.finalize(%{run | anchor: final.id})
    assert box.source_signal_id == input.id
    refute Repo.reload!(steer).completed_at
    refute Repo.reload!(steer).last_attempt_at
    assert {:ok, next} = Admission.admit(steer, steer)
    assert next.signal_id == steer.id
    assert next.conversation.id == run.conversation.id
    assert {:ok, {:preparing, prepared}} = Model.prepare(next)

    assert Ankole.JSON.encode!(prepared.input) =~
             "Next requirement"
  end

  test "stop marks the run's visible preview card as stopped" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)

    {:ok, %{signal: input}} =
      emit_entry(agent.uid, "bot", group_entry(%{text: "Write the report", explicit: true}),
        now: @base_time
      )

    {:ok, run} = Admission.admit(input, input)

    input
    |> Repo.reload!()
    |> Ankole.PreviewFixtures.update!(%{
      provider_message_id: "provider-preview-card",
      checkpoint: %{
        "presentation" => %{"schema_version" => 1, "state" => "working", "answer" => "Part one"}
      }
    })

    {:ok, %{signal: stop}} =
      emit_entry(agent.uid, "bot", group_entry(%{text: "/stop", explicit: true}),
        now: DateTime.add(@base_time, 1)
      )

    assert {:ok, _} = Commands.interrupt(run, stop)

    assert [card] =
             Repo.all(
               from entry in Intent,
                 where:
                   entry.source_signal_id == ^input.id and
                     entry.target_provider_message_id == "provider-preview-card"
             )

    assert card.operation == :edit
    assert get_in(card.payload, ["reply_presentation", "state"]) == "stopped"
    assert get_in(card.payload, ["reply_presentation", "answer"]) == "Part one"
  end

  describe "compression commands" do
    test "/compress is parsed as a control-plane command" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")
      initial_message_count = Repo.aggregate(Message, :count)

      assert {:ok, %{signal: input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "/compress", explicit: true}),
                 now: @base_time
               )

      assert input.type == "command.compress"
      assert input.type == "command.compress"
      assert get_in(input.data, ["entry", "text"]) == "/compress"
      assert get_in(input.data, ["command", "name"]) == "compress"
      assert get_in(input.data, ["command", "raw"]) == "/compress"
      assert Repo.get(Signal, input.id)
      assert Repo.aggregate(Intent, :count) == 0
      assert Repo.aggregate(Message, :count) == initial_message_count
    end

    test "/compress compacts short history below the preferred tail and writes feedback" do
      %{principal: agent} = agent_fixture()
      compact_below(4)
      binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")
      test_pid = self()

      base_url =
        Ankole.AIGatewayCase.start_upstream_server(fn request ->
          send(test_pid, {:gateway_request, request})
          refute Ankole.JSON.encode!(request.body) =~ "MEMORY_ORION"

          {:sse, 200,
           Ankole.AIGatewayCase.openai_response_stream_events(
             "resp_manual_compaction_summary",
             "gpt-compress",
             "## Active Task\nManual compressed history.",
             %{"total_tokens" => 7}
           )}
        end)

      provider_id = "compress-summary-" <> Ecto.UUID.generate()

      assert {:ok, _provider} =
               ProviderConfigs.create_provider(%{
                 provider_id: provider_id,
                 provider_kind: "openai",
                 base_url: "#{base_url}/v1",
                 credential_pool: %{
                   "entries" => [%{"label" => "Default", "api_key" => "sk-compress"}]
                 }
               })

      assert {:ok, _profile} =
               ModelProfiles.put_model_profile(agent.uid, "light", %{
                 provider_id: provider_id,
                 model: "gpt-compress"
               })

      {:ok, conversation} =
        Ankole.AIGatewayCase.ensure_conversation(
          agent.uid,
          Ankole.Sessions.Key.conversation(
            Ankole.ExternalConversationsFixtures.external_conversation_id("lark:chat:group-a")
          )
        )

      {:ok, _packs} = Ankole.Brain.SchemaPacks.install_packs([])

      {:ok, object} =
        Ankole.Brain.Objects.create_object(
          %{
            slug: "concepts/wire-format",
            type: "concept",
            title: "Wire Format",
            body: "fixture"
          },
          agent.uid
        )

      {:ok, _claim} =
        Ankole.Brain.Claims.write_fact(
          %{
            object_slug: object.slug,
            claim: "MEMORY_ORION",
            kind: "fact",
            holder: "world",
            audience_scope: "world",
            notability: "medium",
            confidence: 0.9,
            valid_from: DateTime.utc_now(:microsecond),
            provenance: "test"
          },
          agent.uid
        )

      {:ok, _alias} = Ankole.Brain.Links.add_alias(object.slug, "Wire Format")

      {opening, injection} =
        Ankole.AIGateway.HostedTools.Brain.inject_stateful(
          agent.uid,
          %{
            "tools" => [%{"type" => "brain", "inject" => true}]
          },
          conversation,
          [
            %{
              "type" => "message",
              "role" => "user",
              "content" => [%{"type" => "input_text", "text" => "Wire Format"}]
            }
          ],
          []
        )

      assert [_prompt] = opening
      assert [_pack] = injection["brain_context_pack"]

      old =
        insert_complete_message!(
          agent.uid,
          conversation.id,
          nil,
          [%{"type" => "text", "text" => "old text item should be compactable"}]
        )

      old =
        old
        |> Ecto.Changeset.change(metadata: Map.merge(old.metadata, injection))
        |> Repo.update!()

      middle =
        insert_complete_message!(
          agent.uid,
          conversation.id,
          old.id,
          [
            %{
              "type" => "message",
              "role" => "assistant",
              "content" => [%{"type" => "output_text", "text" => "middle answer"}]
            }
          ]
        )

      tail =
        insert_complete_message!(
          agent.uid,
          conversation.id,
          middle.id,
          [
            %{
              "type" => "message",
              "role" => "user",
              "content" => [%{"type" => "input_text", "text" => "Wire Format: recent tail"}]
            }
          ]
        )

      assert {:ok, %{signal: compress_event}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "/compress", explicit: true}),
                 now: @base_time
               )

      assert {:ok,
              %{
                status: :command_consumed,
                feedback: "Conversation compressed.",
                message: %Message{} = compaction
              }} =
               Commands.process(
                 %{agent_uid: agent.uid, session_id: compress_event.session_id},
                 compress_event
               )

      assert_receive {:gateway_request, request}
      assert request.path == "v1/responses"

      assert compaction.type == "checkpoint"
      assert compaction.status == "complete"
      assert compaction.previous_message_id == tail.id
      assert compaction.metadata["manual"] == true
      assert compaction.metadata["auto"] == false
      assert compaction.content == [CompactionArtifacts.ref_item(compaction.id)]

      assert %CompactionArtifact{} = artifact = Repo.get!(CompactionArtifact, compaction.id)

      assert [checkpoint_pack] = artifact.content["brain_context_pack"]
      assert Ankole.JSON.encode!(checkpoint_pack) =~ "entity: concepts/wire-format"
      assert checkpoint_pack["role"] == "user"
      refute Ankole.JSON.encode!(artifact.content["output"]) =~ "MEMORY_ORION"

      assert artifact.content["retention"]["requested"] == 4
      assert artifact.content["retention"]["actual"] == 2

      assert get_in(artifact.content, ["summary", "text"]) ==
               "## Active Task\nManual compressed history."

      assert %DateTime{} = Repo.get!(Signal, compress_event.id).completed_at

      assert %Intent{payload: %{"text" => "Conversation compressed."}} =
               Repo.get_by!(Intent,
                 source_signal_id: compress_event.id,
                 ai_message_id: compaction.id
               )

      refute_receive {:actor_lane, _envelope}, 100
    end

    test "/compress compacts real Responses role/content text items from live turns" do
      %{principal: agent} = agent_fixture()
      compact_below(1)
      binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")
      test_pid = self()

      base_url =
        Ankole.AIGatewayCase.start_upstream_server(fn request ->
          send(test_pid, {:gateway_request, request})

          {:sse, 200,
           Ankole.AIGatewayCase.openai_response_stream_events(
             "resp_real_role_content_compaction_summary",
             "gpt-compress",
             "## Active Task\nReal role/content history compressed.",
             %{"total_tokens" => 7}
           )}
        end)

      provider_id = "compress-real-role-content-" <> Ecto.UUID.generate()

      assert {:ok, _provider} =
               ProviderConfigs.create_provider(%{
                 provider_id: provider_id,
                 provider_kind: "openai",
                 base_url: "#{base_url}/v1",
                 credential_pool: %{
                   "entries" => [%{"label" => "Default", "api_key" => "sk-compress"}]
                 }
               })

      assert {:ok, _profile} =
               ModelProfiles.put_model_profile(agent.uid, "light", %{
                 provider_id: provider_id,
                 model: "gpt-compress"
               })

      {:ok, conversation} =
        Ankole.AIGatewayCase.ensure_conversation(
          agent.uid,
          Ankole.Sessions.Key.conversation(
            Ankole.ExternalConversationsFixtures.external_conversation_id("lark:chat:group-a")
          )
        )

      old =
        insert_complete_message!(
          agent.uid,
          conversation.id,
          nil,
          [
            %{
              "role" => "user",
              "content" => [
                %{"type" => "input_text", "text" => "phase code ANKOLE_REAL_E2E"}
              ]
            },
            %{
              "type" => "message",
              "role" => "assistant",
              "content" => [%{"type" => "output_text", "text" => "recorded"}]
            }
          ]
        )

      middle =
        insert_complete_message!(
          agent.uid,
          conversation.id,
          old.id,
          [
            %{
              "role" => "user",
              "content" => [%{"type" => "input_text", "text" => "window is Wednesday 19:30"}]
            },
            %{
              "type" => "message",
              "role" => "assistant",
              "content" => [%{"type" => "output_text", "text" => "recorded"}]
            }
          ]
        )

      _tail =
        insert_complete_message!(
          agent.uid,
          conversation.id,
          middle.id,
          [
            %{
              "role" => "user",
              "content" => [%{"type" => "input_text", "text" => "owner is Ada"}]
            },
            %{
              "type" => "message",
              "role" => "assistant",
              "content" => [%{"type" => "output_text", "text" => "recorded"}]
            }
          ]
        )

      assert {:ok, %{signal: compress_event}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "/compress", explicit: true}),
                 now: @base_time
               )

      assert {:ok,
              %{
                status: :command_consumed,
                feedback: "Conversation compressed.",
                message: %Message{} = compaction
              }} =
               Commands.process(
                 %{agent_uid: agent.uid, session_id: compress_event.session_id},
                 compress_event
               )

      assert_receive {:gateway_request, request}
      assert request.path == "v1/responses"
      assert request.body["input"] =~ "phase code ANKOLE_REAL_E2E"

      assert compaction.type == "checkpoint"
      assert compaction.previous_message_id != nil
      assert compaction.content == [CompactionArtifacts.ref_item(compaction.id)]

      assert %CompactionArtifact{} = artifact = Repo.get!(CompactionArtifact, compaction.id)

      assert get_in(artifact.content, ["summary", "text"]) ==
               "## Active Task\nReal role/content history compressed."

      assert %DateTime{} = Repo.get!(Signal, compress_event.id).completed_at
    end

    test "/compress consumes the command when there is no compactable prefix" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")
      initial_message_count = Repo.aggregate(Message, :count)

      {:ok, _conversation} =
        Ankole.AIGatewayCase.ensure_conversation(
          agent.uid,
          Ankole.Sessions.Key.conversation(
            Ankole.ExternalConversationsFixtures.external_conversation_id("lark:chat:group-a")
          )
        )

      assert {:ok, %{signal: compress_event}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "/compress", explicit: true}),
                 now: @base_time
               )

      assert {:ok,
              %{
                status: :command_consumed,
                feedback: "Nothing to compress."
              }} =
               Commands.process(
                 %{agent_uid: agent.uid, session_id: compress_event.session_id},
                 compress_event
               )

      assert %DateTime{} = Repo.get!(Signal, compress_event.id).completed_at

      assert %Intent{payload: %{"text" => "Nothing to compress."}} =
               Repo.get_by!(Intent, source_signal_id: compress_event.id)

      assert Repo.aggregate(Message, :count) == initial_message_count
      refute_receive {:gateway_request, _request}, 100
      refute_receive {:actor_lane, _envelope}, 100
    end
  end

  test "new with instructions opens one fresh conversation without a Worker" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)

    assert {:ok, %{signal: first}} =
             emit_entry(agent.uid, "bot", group_entry(%{text: "Old task", explicit: true}),
               now: @base_time
             )

    key = %{agent_uid: agent.uid, session_id: first.session_id}
    assert {:ok, old} = Admission.admit(key, first)
    assert {:ok, old_context} = Ankole.Sessions.Context.resolve(agent.uid, first.session_id)

    old_prompt =
      Ankole.Sessions.Prompt.system(
        Map.put(%{old | context: old_context}, :available_tool_names, [])
      )

    assert old_prompt =~ "Current drive directory: chats/#{first.conversation_id}/"
    assert old_prompt =~ "The workspace is a temporary working directory."
    refute old_prompt =~ "This is a private conversation with the other person."
    assert {:ok, _} = Run.finalize(old, :silent)

    assert {:ok, %{signal: event}} =
             emit_entry(
               agent.uid,
               "bot",
               group_entry(%{text: "/new Fresh task\nwith context", explicit: true}),
               now: DateTime.add(@base_time, 2)
             )

    assert Commands.route(event) == :run
    assert {:ok, fresh} = Admission.admit(key, event)
    assert fresh.conversation.id != old.conversation.id

    assert {:ok, fresh_context} =
             Ankole.Sessions.Context.resolve(agent.uid, event.session_id)

    fresh_prompt =
      Ankole.Sessions.Prompt.system(
        Map.put(%{fresh | context: fresh_context}, :available_tool_names, [])
      )

    assert fresh_prompt =~ "Current drive directory: chats/#{first.conversation_id}/"
    assert fresh_prompt =~ "Current workspace: /workspace/sessions/#{fresh.workspace_id}"
    assert Repo.get!(Conversation, old.conversation.id).ended_at
    assert fresh.event.data["command"]["argsText"] == "Fresh task\nwith context"
    assert Repo.get!(AgentWorker, agent.uid).state == "absent"
    assert {:ok, adopted} = Admission.admit(key, Repo.reload!(event))
    assert adopted.conversation.id == fresh.conversation.id
  end

  defp insert_complete_message!(agent_uid, conversation_id, previous_message_id, content) do
    {:ok, signal} =
      append_runtime_signal(agent_uid, "compress-history", "conversation.message.addressed",
        now: DateTime.utc_now(:microsecond)
      )

    attrs = %{
      subject_uid: agent_uid,
      metadata: %{"request_metadata" => %{"signal_id" => signal.id}},
      request_items: content
    }

    attrs =
      case previous_message_id do
        nil -> Map.put(attrs, :conversation_id, conversation_id)
        message_id -> Map.put(attrs, :previous_response_id, "resp_#{message_id}")
      end

    {:ok, message} = start_response_run(attrs)
    {:ok, message} = ResponseCommit.commit_complete(message, [])

    message
  end

  # These conversations are a few turns long, so the retained tail must stay
  # below them for a prefix to exist. What is under test is the command path,
  # not the row floor.
  defp compact_below(tail_rows) do
    merged = Map.put(CompactionPolicy.config(), "tail_rows", tail_rows)

    assert {:ok, _config} =
             Ankole.AppConfigure.put_global(
               Ankole.AIGateway.CompactionPolicy.config_definition(),
               merged
             )

    on_exit(fn ->
      _result =
        Ankole.AppConfigure.delete_global(Ankole.AIGateway.CompactionPolicy.config_definition())

      :ok
    end)
  end
end
