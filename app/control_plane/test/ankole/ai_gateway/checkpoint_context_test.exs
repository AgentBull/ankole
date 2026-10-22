defmodule Ankole.AIGateway.CheckpointContextTest do
  alias Ankole.AIGateway.ToolResultJournal
  alias Ankole.AIGateway.ResponseCommit
  alias Ankole.AIGateway.ResponseChain
  alias Ankole.AIGateway.CompactionRequests
  alias Ankole.AIGateway.CompactionPolicy
  use Ankole.AIGatewayCase

  alias Ankole.AIGateway.CompactionArtifacts
  alias Ankole.AIGateway.Schemas.CompactionArtifact
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.AIGateway.StatefulLifecycle
  alias Ankole.AIGateway.StatefulResponses
  alias Ankole.Brain.Claims
  alias Ankole.Brain.Links
  alias Ankole.Brain.Objects
  alias Ankole.Brain.SchemaPacks
  alias Ankole.Repo

  setup do
    %{principal: agent} = agent_fixture()
    {:ok, _} = SchemaPacks.install_packs([])

    assert {:ok, :canonical} =
             Repo.transact(fn repo ->
               :ok =
                 Objects.ensure_canonical_object_in_tx(repo, agent.uid, :agent, "Review agent")

               {:ok, :canonical}
             end)

    fact!(agent, "agents/#{agent.uid}", "AGENT_MEMORY")

    {:ok, object} =
      Objects.create_object(
        %{slug: "concepts/wire-format", type: "concept", title: "Wire Format"},
        agent.uid
      )

    fact!(agent, object.slug, "TASK_MEMORY")
    {:ok, _} = Links.add_alias(object.slug, "Wire Format")

    {:ok, conversation} =
      Ankole.AIGatewayCase.ensure_conversation(agent.uid, "checkpoint-#{Ecto.UUID.generate()}")

    event = event!(agent, conversation)
    configure_compaction!(100_000)
    %{agent: agent, conversation: conversation, event: event}
  end

  test "memory over budget follows the selected overflow policy", context do
    configure_compaction!(8_000)

    Enum.each(1..5, fn index ->
      fact!(
        context.agent,
        "agents/#{context.agent.uid}",
        "Budget #{index}: " <> String.duplicate("budget_fact ", 150)
      )
    end)

    provider!(context.agent, fn request ->
      {:sse, 200,
       openai_response_stream_events(
         "resp_summary",
         request.body["model"],
         "## Active Task\n" <> String.duplicate("summary ", 3_300)
       )}
    end)

    _journal = tool_round!(context, "budget", 160_000)
    request = request(context, [text("user", "continue")])

    assert {:error,
            {:context_overflow,
             %{reason: "compaction_output_over_budget", truncation: "disabled"}}} =
             StatefulLifecycle.prepare_websocket_request(
               context.agent.uid,
               request
             )

    assert Repo.aggregate(CompactionArtifact, :count) == 0

    assert {:ok, provider_request, result} =
             StatefulLifecycle.prepare_websocket_request(
               context.agent.uid,
               Map.put(request, "truncation", "auto")
             )

    artifact = Repo.get!(CompactionArtifact, result.message.previous_message_id)
    assert artifact.content["retention"]["strategy"] == "stable_tail"
    assert memory_count(provider_request.response_context.request["input"]) == 1
    assert artifact.content["brain_context_pack"] != []
    assert Repo.aggregate(CompactionArtifact, :count) == 1
  end

  test "successful replay recovery preserves originals and adds memory only to the provider copy",
       context do
    {:ok, previous} =
      StatefulResponses.start_planned_response_run(%{
        subject_uid: context.agent.uid,
        conversation_id: context.conversation.id,
        request_items: [text("user", "Earlier work ORIGINAL_REPLAY")]
      })

    sealed = %{
      "type" => "reasoning",
      "id" => "rs_old",
      "summary" => [%{"type" => "summary_text", "text" => "Prior work"}],
      "encrypted_content" => "OLD_SEALED_STATE"
    }

    {:ok, _} =
      ResponseCommit.commit_complete(
        previous,
        [sealed, text("assistant", "Earlier answer")],
        usage(100)
      )

    recorded = start_supervised!({Agent, fn -> %{light: [], main: []} end})
    owner = self()

    provider!(context.agent, fn request ->
      if request.body["model"] == "gpt-compact-light" do
        Agent.update(recorded, &Map.update!(&1, :light, fn xs -> xs ++ [request.body] end))

        {:sse, 200,
         openai_response_stream_events(
           "resp_summary",
           request.body["model"],
           "## Active Task\nContinue the Wire Format task."
         )}
      else
        attempt =
          Agent.get_and_update(recorded, fn state ->
            main = state.main ++ [request.body]
            {length(main), %{state | main: main}}
          end)

        if attempt == 1 do
          {:json, 400,
           %{
             "error" => %{
               "type" => "invalid_request_error",
               "param" => "input",
               "message" => "Historical sealed item rejected"
             }
           }}
        else
          send(owner, {:recovery_retry_ready, self()})

          receive do
            :finish_recovery_retry -> :ok
          after
            5_000 -> flunk("recovery retry was not released")
          end

          {:sse, 200,
           openai_response_stream_events(
             "resp_recovered",
             request.body["model"],
             "Task continued",
             %{"total_tokens" => 100}
           )}
        end
      end
    end)

    supervisor = start_supervised!(Task.Supervisor)

    response_task =
      Task.Supervisor.async_nolink(
        supervisor,
        Repo.bind_tenant(fn ->
          with {:ok, stream, _} <-
                 AIGateway.open_websocket_stream(
                   context.agent.uid,
                   request(context, [text("user", "Wire Format task")])
                 ) do
            collect_events(stream, [])
          end
        end)
      )

    assert_receive {:recovery_retry_ready, retry_pid}, 5_000

    generating =
      Repo.get_by!(Message, conversation_id: context.conversation.id, status: "generating")

    checkpoint = Repo.get!(Message, generating.previous_message_id)
    assert checkpoint.type == :checkpoint
    refute Map.has_key?(checkpoint.metadata, "issuer")
    assert_task_memory!(generating.previous_message_id)
    refute Ankole.JSON.encode!(generating.content) =~ "AGENT_MEMORY"
    refute Map.has_key?(generating.metadata, "brain_injection")
    assert is_list(generating.metadata["brain_pointer_lines"])
    assert generating.metadata["request_item_count"] == 1

    send(retry_pid, :finish_recovery_retry)
    assert {:ok, events} = Task.await(response_task, 5_000)

    assert %{"response" => %{"status" => "completed", "id" => response_id}} =
             Enum.find(events, &(&1["type"] == "response.completed"))

    %{light: [summary], main: [initial, recovered]} = Agent.get(recorded, & &1)
    assert memory_count(initial["input"]) == 1
    assert Ankole.JSON.encode!(initial) =~ "OLD_SEALED_STATE"
    assert Ankole.JSON.encode!(initial) =~ "ORIGINAL_REPLAY"
    assert Ankole.JSON.encode!(summary) =~ "ORIGINAL_REPLAY"
    assert Ankole.JSON.encode!(Repo.get!(Message, previous.id).content) =~ "ORIGINAL_REPLAY"
    refute Ankole.JSON.encode!(recovered) =~ "OLD_SEALED_STATE"
    refute Ankole.JSON.encode!(summary) =~ "AGENT_MEMORY"
    assert memory_count(recovered["input"]) == 1

    message = ResponseChain.get_message(response_id)
    assert message.id == generating.id
    refute Ankole.JSON.encode!(message.content) =~ "AGENT_MEMORY"
    refute Map.has_key?(message.metadata, "brain_injection")
    assert is_list(message.metadata["brain_pointer_lines"])
    assert message.metadata["request_item_count"] == 1
    originals = Enum.take(message.content, message.metadata["request_item_count"])
    assert originals == [text("user", "Wire Format task")]

    assert recovered["input"] ==
             Ankole.AIGateway.HostedTools.Brain.replay(
               Enum.drop(recovered["input"], -1) ++ originals,
               Map.put(message.metadata, "brain_context_pack", [])
             )

    context = %{context | event: event!(context.agent, context.conversation)}

    assert {:ok, next, _} =
             StatefulLifecycle.prepare_websocket_request(
               context.agent.uid,
               request(context, [text("user", "continue")])
             )

    assert memory_count(next.response_context.request["input"]) == 1
  end

  test "a checkpoint follows its requested anchor rather than a newer conversation branch",
       context do
    {:ok, object} =
      Objects.create_object(
        %{slug: "concepts/frame-header", type: "concept", title: "Frame Header"},
        context.agent.uid
      )

    fact!(context.agent, object.slug, "OTHER_TASK_MEMORY")
    {:ok, _} = Links.add_alias(object.slug, "Frame Header")

    provider!(context.agent, fn request ->
      {:sse, 200,
       openai_response_stream_events(
         "resp_summary",
         request.body["model"],
         "## Active Task\nContinue the Wire Format task."
       )}
    end)

    anchor = tool_round!(context, "original_branch", 160_000)

    {:ok, newer} =
      StatefulResponses.start_planned_response_run(%{
        subject_uid: context.agent.uid,
        previous_response_id: "resp_#{anchor.id}",
        request_items: [text("user", "Frame Header task")]
      })

    {:ok, _} =
      ResponseCommit.commit_complete(newer, [text("assistant", "Newer answer")], usage(100))

    branch_request =
      context
      |> request([])
      |> Map.delete("conversation")
      |> Map.put("previous_response_id", "resp_#{anchor.id}")

    assert {:ok, _, branch} =
             StatefulLifecycle.prepare_websocket_request(
               context.agent.uid,
               branch_request
             )

    checkpoint_id = branch.message.previous_message_id
    assert_task_memory!(checkpoint_id)
    pack = Repo.get!(CompactionArtifact, checkpoint_id).content["brain_context_pack"]
    refute Ankole.JSON.encode!(pack) =~ "OTHER_TASK_MEMORY"
    assert Repo.get!(Message, checkpoint_id).previous_message_id == anchor.id
  end

  test "ordinary tool continuations and consecutive checkpoints use the latest user task",
       context do
    owner = self()

    provider!(context.agent, fn request ->
      send(owner, {:summary_input, request.body})

      {:sse, 200,
       openai_response_stream_events(
         "resp_summary",
         request.body["model"],
         "## Active Task\nContinue the Wire Format task."
       )}
    end)

    _first_journal = tool_round!(context, "first", 160_000)

    assert {:ok, second_request, second} =
             StatefulLifecycle.prepare_websocket_request(
               context.agent.uid,
               request(context, [])
             )

    first_checkpoint = second.message.previous_message_id
    assert_task_memory!(first_checkpoint)
    assert memory_count(second_request.response_context.request["input"]) == 1
    refute Map.has_key?(second.message.metadata, "brain_injection")
    journal!(context, second.message, "second", 160_000)

    assert {:ok, third_request, third} =
             StatefulLifecycle.prepare_websocket_request(
               context.agent.uid,
               request(context, [])
             )

    second_checkpoint = third.message.previous_message_id
    refute first_checkpoint == second_checkpoint
    assert_task_memory!(second_checkpoint)
    assert memory_count(third_request.response_context.request["input"]) == 1
    journal!(context, third.message, "third", 100)

    assert {:ok, fourth_request, fourth} =
             StatefulLifecycle.prepare_websocket_request(
               context.agent.uid,
               request(context, [])
             )

    assert Repo.get!(Message, fourth.message.previous_message_id).type == :message
    assert memory_count(fourth_request.response_context.request["input"]) == 1
    refute Map.has_key?(fourth.message.metadata, "brain_injection")
    assert Repo.aggregate(CompactionArtifact, :count) == 2

    for _ <- 1..2 do
      assert_receive {:summary_input, summary}, 1_000
      refute Ankole.JSON.encode!(summary) =~ "AGENT_MEMORY"
      refute Ankole.JSON.encode!(summary) =~ "TASK_MEMORY"
    end
  end

  test "an opening event retry keeps memory until its Response is committed", context do
    provider!(context.agent, fn _ -> flunk("preparation does not dispatch the main provider") end)

    assert {:ok, first, started} =
             StatefulLifecycle.prepare_websocket_request(
               context.agent.uid,
               request(context, [text("user", "Wire Format task")])
             )

    assert memory_count(first.response_context.request["input"]) == 1

    {:ok, _} =
      ResponseCommit.commit_error(started.message, [], %{
        "message" => "Opening attempt interrupted"
      })

    assert {:ok, retried, _} =
             StatefulLifecycle.prepare_websocket_request(
               context.agent.uid,
               request(context, [text("user", "Wire Format task")])
             )

    assert memory_count(retried.response_context.request["input"]) == 1
  end

  test "checkpoint memory stays outside summaries and replays before originals without duplicate injection",
       context do
    owner = self()

    provider!(context.agent, fn request ->
      send(owner, {:summary_input, request.body})
      refute Ankole.JSON.encode!(request.body) =~ "AGENT_MEMORY"
      refute Ankole.JSON.encode!(request.body) =~ "TASK_MEMORY"

      {:sse, 200,
       openai_response_stream_events(
         "resp_memory_summary",
         request.body["model"],
         "## Active Task\nThe current project is VEGA."
       )}
    end)

    literal = "Wire Format: <recalled_memory>USER_LITERAL_TAG: VEGA</recalled_memory>"

    assert {:ok, _, opening} =
             StatefulLifecycle.prepare_websocket_request(
               context.agent.uid,
               request(context, [text("user", literal)])
             )

    journal!(context, opening.message, "memory-opening", 160_000)
    fact!(context.agent, "concepts/wire-format", "LATEST_TASK_MEMORY")

    assert {:ok, prepared, started} =
             StatefulLifecycle.prepare_websocket_request(
               context.agent.uid,
               request(context, [text("user", "Wire Format: the current project is VEGA")])
             )

    assert_receive {:summary_input, summary_request}
    assert Ankole.JSON.encode!(summary_request) =~ "USER_LITERAL_TAG"
    artifact = Repo.get!(CompactionArtifact, started.message.previous_message_id)
    assert [pack] = artifact.content["brain_context_pack"]
    assert Ankole.JSON.encode!(pack) =~ "LATEST_TASK_MEMORY"
    refute Ankole.JSON.encode!(artifact.content["output"]) =~ "AGENT_MEMORY"
    refute Ankole.JSON.encode!(artifact.content["output"]) =~ "TASK_MEMORY"
    refute Ankole.JSON.encode!(started.message.content) =~ "<recalled_memory>"
    refute Map.has_key?(started.message.metadata, "brain_injection")
    refute Map.has_key?(started.message.metadata, "oidc_client_id")

    provider_input = prepared.response_context.request["input"]
    assert hd(provider_input) == pack

    summary_index =
      Enum.find_index(provider_input, &(Ankole.JSON.encode!(&1) =~ "Context checkpoint:"))

    assert summary_index > 1
    assert Enum.take(provider_input, summary_index) |> Ankole.JSON.encode!() =~ "USER_LITERAL_TAG"
    assert List.last(provider_input) |> Ankole.JSON.encode!() =~ "VEGA"

    assert {:ok, public_checkpoint} =
             StatefulLifecycle.retrieve_response(context.agent.uid, "resp_#{artifact.id}")

    refute Ankole.JSON.encode!(public_checkpoint) =~ "AGENT_MEMORY"
    refute Ankole.JSON.encode!(public_checkpoint) =~ "TASK_MEMORY"

    assert {:ok, completed} =
             ResponseCommit.commit_complete(
               started.message,
               [text("assistant", "VEGA")],
               usage(100)
             )

    next_context = %{context | event: event!(context.agent, context.conversation)}

    next_request =
      next_context
      |> request([text("user", "Wire Format: continue")])
      |> Map.delete("conversation")
      |> Map.put("previous_response_id", "resp_#{completed.id}")

    assert {:ok, next, continuation} =
             StatefulLifecycle.prepare_websocket_request(
               context.agent.uid,
               next_request
             )

    next_input = next.response_context.request["input"]
    assert hd(next_input) == pack
    assert Enum.count(next_input, &(Ankole.JSON.encode!(&1) =~ "AGENT_MEMORY")) == 1
    refute Ankole.JSON.encode!(continuation.message.content) =~ "AGENT_MEMORY"
    refute Ankole.JSON.encode!(continuation.message.content) =~ "TASK_MEMORY"
  end

  test "upstream checkpoints keep fresh memory separate from provider compaction input and output",
       context do
    {:ok, _} =
      Ankole.AppConfigure.put_global(
        Ankole.AIGateway.CompactionPolicy.config_definition(),
        Map.put(CompactionPolicy.config(), "upstream", true)
      )

    native_output = [%{"type" => "compaction", "encrypted_content" => "provider-memory-opaque"}]
    owner = self()

    provider!(context.agent, fn request ->
      assert List.last(request.body["input"]) == %{"type" => "compaction_trigger"}
      refute Ankole.JSON.encode!(request.body) =~ "AGENT_MEMORY"
      refute Ankole.JSON.encode!(request.body) =~ "TASK_MEMORY"
      send(owner, :upstream_compacted)
      {:sse, 200, openai_compaction_stream_events("resp_memory_native", native_output)}
    end)

    tool_round!(context, "memory-native", 160_000)

    assert {:ok, prepared, started} =
             StatefulLifecycle.prepare_websocket_request(
               context.agent.uid,
               request(context, [text("user", "Wire Format: continue")])
             )

    assert_receive :upstream_compacted
    artifact = Repo.get!(CompactionArtifact, started.message.previous_message_id)
    assert artifact.content["version"] == 3
    assert artifact.content["output"] == native_output
    assert_task_memory!(artifact.id)
    assert [pack] = artifact.content["brain_context_pack"]
    assert Enum.take(prepared.response_context.request["input"], 2) == [pack | native_output]
  end

  test "automatic truncation retains a fresh checkpoint memory pack after summary failure",
       context do
    provider!(context.agent, fn request ->
      refute Ankole.JSON.encode!(request.body) =~ "AGENT_MEMORY"
      refute Ankole.JSON.encode!(request.body) =~ "TASK_MEMORY"
      {:sse, 200, openai_response_stream_events("resp_memory_empty", request.body["model"], "")}
    end)

    tool_round!(context, "memory-truncate", 160_000)

    assert {:ok, prepared, started} =
             StatefulLifecycle.prepare_websocket_request(
               context.agent.uid,
               context
               |> request([text("user", "Wire Format: VEGA")])
               |> Map.put("truncation", "auto")
             )

    artifact = Repo.get!(CompactionArtifact, started.message.previous_message_id)
    assert artifact.content["retention"]["strategy"] == "stable_tail"
    assert_task_memory!(artifact.id)
    assert [pack] = artifact.content["brain_context_pack"]
    assert hd(prepared.response_context.request["input"]) == pack
    refute Ankole.JSON.encode!(artifact.content["output"]) =~ "AGENT_MEMORY"
    refute Ankole.JSON.encode!(artifact.content["output"]) =~ "TASK_MEMORY"
  end

  test "stored standalone compaction stores a separate fresh pack", context do
    provider!(context.agent, fn request ->
      refute Ankole.JSON.encode!(request.body) =~ "AGENT_MEMORY"
      refute Ankole.JSON.encode!(request.body) =~ "TASK_MEMORY"

      {:sse, 200,
       openai_response_stream_events(
         "resp_memory_standalone",
         request.body["model"],
         "## Active Task\nVEGA summary"
       )}
    end)

    tail = tool_round!(context, "memory-standalone", 160_000)

    assert {:ok, body} =
             CompactionRequests.compact_response(context.agent.uid, %{
               "model" => "primary",
               "input" => [text("user", "Wire Format: VEGA")],
               "store" => true,
               "previous_response_id" => "resp_#{tail.id}"
             })

    refute Ankole.JSON.encode!(body) =~ "AGENT_MEMORY"
    refute Ankole.JSON.encode!(body) =~ "TASK_MEMORY"
    "resp_" <> checkpoint_id = body["ankole"]["response_id"]
    assert_task_memory!(checkpoint_id)
    artifact = Repo.get!(CompactionArtifact, checkpoint_id)
    refute Ankole.JSON.encode!(artifact.content["output"]) =~ "AGENT_MEMORY"
    refute Ankole.JSON.encode!(artifact.content["output"]) =~ "TASK_MEMORY"
  end

  test "OIDC evidence excludes opening memory and checkpoint memory", context do
    provider!(context.agent, fn _ -> flunk("preparation does not dispatch the main provider") end)

    {:ok, plain_conversation} =
      Ankole.AIGatewayCase.ensure_conversation(context.agent.uid, "plain-opening")

    plain = %{
      context
      | conversation: plain_conversation,
        event: event!(context.agent, plain_conversation)
    }

    assert {:ok, _, plain_started} =
             StatefulLifecycle.prepare_websocket_request(
               context.agent.uid,
               request(plain, [text("user", "Wire Format")])
             )

    assert [_pack] = plain_started.message.metadata["brain_context_pack"]
    refute Ankole.JSON.encode!(plain_started.message.content) =~ "AGENT_MEMORY"
    refute Map.has_key?(plain_started.message.metadata, "oidc_client_id")
    assert {:ok, _} = ResponseCommit.commit_complete(plain_started.message, [])

    assert {:ok, _, started} =
             StatefulLifecycle.prepare_websocket_request(
               context.agent.uid,
               request(context, [text("user", "Wire Format")]),
               oidc_client_id: "memory-client"
             )

    assert [_pack] = started.message.metadata["brain_context_pack"]
    refute Ankole.JSON.encode!(started.message.content) =~ "AGENT_MEMORY"

    assert {:ok, complete} =
             ResponseCommit.commit_complete(started.message, [text("assistant", "answer")])

    {:ok, artifact} =
      CompactionArtifacts.insert_artifact(%{
        subject_uid: context.agent.uid,
        conversation_id: context.conversation.id,
        summary_text: "checkpoint summary",
        brain_context_pack: started.message.metadata["brain_context_pack"]
      })

    assert {:ok, _} =
             ResponseChain.create_compaction_checkpoint(%{
               subject_uid: context.agent.uid,
               previous_response_id: "resp_#{complete.id}",
               artifact: artifact,
               metadata: %{"oidc_client_id" => "memory-client"}
             })

    evidence =
      Ankole.AIGateway.OIDCClientConversations.read("memory-client", context.conversation.id)

    refute Ankole.JSON.encode!(evidence) =~ "AGENT_MEMORY"
    refute Ankole.JSON.encode!(evidence) =~ "TASK_MEMORY"
    refute Ankole.JSON.encode!(evidence) =~ "memory:"
    assert Ankole.JSON.encode!(evidence) =~ "Wire Format"
  end

  defp assert_task_memory!(checkpoint_id) do
    pack = Repo.get!(CompactionArtifact, checkpoint_id).content["brain_context_pack"]
    assert Ankole.JSON.encode!(pack) =~ "AGENT_MEMORY"
    assert Ankole.JSON.encode!(pack) =~ "TASK_MEMORY"
  end

  defp request(context, input) do
    %{
      "model" => "primary",
      "input" => input,
      "store" => true,
      "conversation" => "conv_#{context.conversation.id}",
      "tools" => [
        %{"type" => "brain", "inject" => true},
        %{
          "type" => "function",
          "name" => "command",
          "parameters" => %{"type" => "object", "properties" => %{}}
        }
      ],
      "metadata" => %{"signal_id" => context.event.id}
    }
  end

  defp tool_round!(context, call_id, tokens) do
    {:ok, _, started} =
      StatefulLifecycle.prepare_websocket_request(
        context.agent.uid,
        request(context, [text("user", "Wire Format task")])
      )

    journal!(context, started.message, call_id, tokens)
  end

  defp journal!(context, message, call_id, tokens) do
    call = %{
      "type" => "function_call",
      "call_id" => call_id,
      "name" => "command",
      "arguments" => "{}",
      "status" => "completed"
    }

    {:ok, completed} = ResponseCommit.commit_complete(message, [call], usage(tokens))

    assert {:ok, journal} =
             Repo.transact(fn repo ->
               case ToolResultJournal.record_tool_results_in_tx(repo, %{
                      subject_uid: context.agent.uid,
                      previous_response_id: "resp_#{completed.id}",
                      request_items: [
                        %{
                          "type" => "function_call_output",
                          "call_id" => call_id,
                          "output" => "Command completed"
                        }
                      ],
                      metadata: %{"request_metadata" => %{"signal_id" => context.event.id}}
                    }) do
                 {:ok, journal, _} -> {:ok, journal}
                 error -> error
               end
             end)

    journal
  end

  defp provider!(agent, handler) do
    url = start_upstream_server(handler)
    id = "checkpoint-#{Ecto.UUID.generate()}"

    {:ok, _} =
      ProviderConfigs.create_provider(%{
        provider_id: id,
        provider_kind: "openai",
        base_url: "#{url}/v1",
        credential_pool: %{"entries" => [%{"label" => "Fixture", "api_key" => "sk-fixture"}]},
        connection_options: %{"transport" => %{}}
      })

    for {profile, model} <- [{"primary", "gpt-main"}, {"light", "gpt-compact-light"}] do
      {:ok, _} =
        ModelProfiles.put_model_profile(agent.uid, profile, %{provider_id: id, model: model})
    end
  end

  defp configure_compaction!(max_tokens) do
    {:ok, _} =
      Ankole.AppConfigure.put_global(
        Ankole.AIGateway.CompactionPolicy.config_definition(),
        Map.merge(CompactionPolicy.config(), %{
          "threshold" => 0.5,
          "max_threshold_tokens" => max_tokens,
          "tail_rows" => 1
        })
      )

    on_exit(fn ->
      Ankole.AppConfigure.delete_global(Ankole.AIGateway.CompactionPolicy.config_definition())
    end)
  end

  defp fact!(agent, slug, claim) do
    {:ok, _} =
      Claims.write_fact(
        %{
          object_slug: slug,
          claim: claim,
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
  end

  defp event!(agent, conversation) do
    {:ok, event} =
      Repo.transact(fn repo ->
        Ankole.Signals.accept_in_tx(repo, %{
          source: "test://checkpoint",
          id: Ecto.UUID.generate(),
          type: "test.source",
          data: %{"text" => "Wire Format task"},
          target: %{agent_uid: agent.uid, session_id: conversation.conversation_key},
          authorization: Ankole.Principals.WorkAccess.service()
        })
      end)

    event
  end

  defp text(role, body),
    do: %{
      "type" => "message",
      "role" => role,
      "content" => [%{"type" => "input_text", "text" => body}]
    }

  defp usage(tokens), do: %{"usage" => %{"totalTokens" => tokens}}

  defp memory_count(items),
    do: Enum.count(items, &(Ankole.JSON.encode!(&1) =~ "<recalled_memory>"))

  defp collect_events(stream, events) do
    with :ok <- AIGateway.read_response_stream(stream, 1) do
      receive do
        {:ai_gateway_response_stream, ref, :events, batch, :continue} when ref == stream.ref ->
          collect_events(stream, events ++ batch)

        {:ai_gateway_response_stream, ref, :events, batch, {:terminal, _}}
        when ref == stream.ref ->
          {:ok, events ++ batch}
      after
        1_000 -> {:error, :response_stream_receive_timeout}
      end
    end
  end
end
