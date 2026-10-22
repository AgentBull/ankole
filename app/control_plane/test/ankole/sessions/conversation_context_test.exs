defmodule Ankole.Sessions.ConversationContextTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures
  import Ankole.AIGatewayCase, only: [start_response_run: 1]
  alias Ankole.AIGateway
  alias Ankole.AIGateway.ResponseCommit
  alias Ankole.Sessions.{ConversationContext, ModelHistory}

  alias Ankole.Conversations
  alias Ankole.Signals

  setup do
    %{principal: human} = human_fixture()
    %{principal: agent} = agent_fixture(%{owner_principal_uid: human.uid})

    attrs = %{
      conversation_id: Ecto.UUID.generate(),
      message_id: Ecto.UUID.generate(),
      agent_uid: agent.uid,
      text: "First question"
    }

    {:ok, detail} = Ankole.ConversationsFixtures.create(human.uid, attrs)

    %{
      human: human,
      agent: agent,
      conversation: detail.conversation,
      model_conversation_id: detail.model_conversation_id,
      first_id: attrs.message_id
    }
  end

  test "a report from this Agent's cron session is new context, while own replies and signal input are excluded",
       context do
    session_id = session_key(context)
    first = Repo.get_by!(Ankole.Signals.Signal, message_id: context.first_id)

    {:ok, %{messages: [own]}} =
      in_tx(fn ->
        Ankole.ConversationsFixtures.post_statement_in_tx(Repo, first, "Own answer")
      end)

    cron = append_report(context, "Cron report")
    next_id = Ecto.UUID.generate()

    {:ok, _} =
      Ankole.ConversationsFixtures.post(context.human.uid, context.conversation.id, %{
        message_id: next_id,
        text: "Next question"
      })

    assert {:ok, snapshot} =
             Conversations.context_snapshot(
               context.conversation.id,
               session_id,
               0,
               [context.first_id, next_id]
             )

    assert Enum.map(snapshot.messages, & &1.id) == [cron.id]
    assert cron.author_uid == own.author_uid
    assert cron.session_id != own.session_id
    assert snapshot.max_seq == 4
  end

  test "the bound keeps the latest reports in sequence order and advances past the older omitted reports",
       context do
    reports = for index <- 1..4, do: append_report(context, "Report #{index}")

    assert {:ok, snapshot} =
             Conversations.context_snapshot(
               context.conversation.id,
               session_key(context),
               0,
               [context.first_id],
               limit: 2
             )

    assert Enum.map(snapshot.messages, & &1.id) == Enum.map(Enum.take(reports, -2), & &1.id)
    assert snapshot.max_seq == 5

    assert {:ok, %{messages: [], max_seq: 5}} =
             Conversations.context_snapshot(
               context.conversation.id,
               session_key(context),
               snapshot.max_seq,
               []
             )
  end

  test "a statement committed after the recorded snapshot enters the next request", context do
    first_report = append_report(context, "Before the request")
    session_id = session_key(context)

    assert {:ok, first} =
             Conversations.context_snapshot(context.conversation.id, session_id, 0, [
               context.first_id
             ])

    assert Enum.map(first.messages, & &1.id) == [first_report.id]

    late_report = append_report(context, "During execution")

    assert {:ok, next} =
             Conversations.context_snapshot(
               context.conversation.id,
               session_id,
               first.max_seq,
               []
             )

    assert Enum.map(next.messages, & &1.id) == [late_report.id]
  end

  test "a missing watermark reads the same bounded reports again",
       context do
    report = append_report(context, "Keep this report")
    session_id = session_key(context)

    assert {:ok, consumed} =
             Conversations.context_snapshot(context.conversation.id, session_id, 0, [
               context.first_id
             ])

    assert {:ok, %{messages: []}} =
             Conversations.context_snapshot(
               context.conversation.id,
               session_id,
               consumed.max_seq,
               []
             )

    assert {:ok, restored} =
             Conversations.context_snapshot(context.conversation.id, session_id, 0, [
               context.first_id
             ])

    assert Enum.map(restored.messages, & &1.id) == [report.id]
  end

  test "caller metadata records consumed reports and a retracted visible round reads them again",
       context do
    report = append_report(context, "Read this public report")
    run = context_run(context)
    first = ConversationContext.append(run, %{"metadata" => %{}, "input" => []})

    assert first["metadata"]["conversation_read"]["id"] == context.conversation.id
    assert first["metadata"]["conversation_read"]["max_seq"] == 2

    assert MapSet.new(first["metadata"]["conversation_read"]["message_ids"]) ==
             MapSet.new([context.first_id, report.id])

    assert Ankole.JSON.encode!(first["input"]) =~ report.text

    {:ok, response} =
      start_response_run(%{
        subject_uid: context.agent.uid,
        conversation_id: context.model_conversation_id,
        metadata: %{"request_metadata" => first["metadata"]}
      })

    {:ok, response} = ResponseCommit.commit_complete(response, [])

    assert ConversationContext.read_seq(
             context.agent.uid,
             context.model_conversation_id,
             context.conversation.id
           ) == 2

    assert ConversationContext.append(run, %{"metadata" => %{}, "input" => []})["input"] == []

    assert {:ok, %{status: :retracted}} =
             in_tx(fn ->
               AIGateway.retract_visible_suffix_in_tx(
                 Repo,
                 context.agent.uid,
                 context.model_conversation_id,
                 ["resp_#{response.id}"]
               )
             end)

    repeated = ConversationContext.append(run, %{"metadata" => %{}, "input" => []})
    assert Ankole.JSON.encode!(repeated["input"]) =~ report.text
  end

  test "ending model history naturally gives the next model conversation no read position",
       context do
    report = append_report(context, "Report before reset")

    {:ok, response} =
      start_response_run(%{
        subject_uid: context.agent.uid,
        conversation_id: context.model_conversation_id,
        metadata: %{
          "request_metadata" => %{
            "conversation_read" => %{"id" => context.conversation.id, "max_seq" => report.seq}
          }
        }
      })

    {:ok, _} = ResponseCommit.commit_complete(response, [])
    session = Ankole.Sessions.Key.conversation(context.conversation.id)

    assert {:ok, _} =
             in_tx(fn ->
               ModelHistory.end_active_conversation_in_tx(
                 Repo,
                 context.agent.uid,
                 session,
                 DateTime.utc_now(:microsecond)
               )
             end)

    assert {:ok, successor} =
             in_tx(fn ->
               AIGateway.ensure_conversation_in_tx(Repo, context.agent.uid, session)
             end)

    assert successor.id != context.model_conversation_id
    run = %{context_run(context) | conversation: successor}

    assert Ankole.JSON.encode!(
             ConversationContext.append(run, %{"metadata" => %{}, "input" => []})["input"]
           ) =~ report.text
  end

  for change <- [:edit, :remove] do
    test "#{change} preserves completed model input and keeps the read watermark", context do
      report = append_report(context, "Background before execution")
      run = context_run(context)
      first = ConversationContext.append(run, %{"metadata" => %{}, "input" => []})

      {:ok, response} =
        start_response_run(%{
          subject_uid: context.agent.uid,
          conversation_id: context.model_conversation_id,
          request_items: first["input"],
          metadata: %{
            "request_metadata" => Map.put(first["metadata"], "signal_id", run.signal_id)
          }
        })

      {:ok, response} = ResponseCommit.commit_complete(response, [])

      case unquote(change) do
        :edit ->
          assert {:ok, _} =
                   in_tx(fn -> Ankole.Ash.update(report, :edit, %{text: "Edited later"}) end)

        :remove ->
          assert {:ok, _} = in_tx(fn -> Ankole.Ash.destroy(report, :remove) end)
      end

      Ankole.DataCase.assert_persisted_equal(Repo.reload!(response), response)
      assert Enum.any?(response.content, &(Ankole.JSON.encode!(&1) =~ report.text))
      assert ConversationContext.append(run, %{"metadata" => %{}, "input" => []})["input"] == []
    end
  end

  test "terminal checks distinguish withdrawn background from the current input", context do
    report = append_report(context, "Background read by this round")
    run = context_run(context)
    first = ConversationContext.append(run, %{"metadata" => %{}, "input" => []})

    {:ok, response} =
      start_response_run(%{
        subject_uid: context.agent.uid,
        conversation_id: context.model_conversation_id,
        request_items: first["input"],
        metadata: %{"request_metadata" => Map.put(first["metadata"], "signal_id", run.signal_id)}
      })

    {:ok, _} = ResponseCommit.commit_complete(response, [])
    signal = Repo.get!(Signals.Signal, run.signal_id)

    assert {:ok, _} =
             in_tx(fn -> Ankole.Ash.update(report, :edit, %{text: "Edited while generating"}) end)

    assert :ok =
             Ankole.Sessions.Queue.ensure_event_source_live_in_tx(
               Repo,
               signal,
               DateTime.utc_now()
             )

    Repo.delete!(report)

    assert {:error, :signal_context_canceled} =
             Ankole.Sessions.Queue.ensure_event_source_live_in_tx(
               Repo,
               signal,
               DateTime.utc_now()
             )
  end

  for upstream? <- [false, true] do
    @tag timeout: 60_000
    test "automatic #{if upstream?, do: "native", else: "local"} checkpoint does not consume a report after provider failure",
         context do
      upstream? = unquote(upstream?)
      alias Ankole.AIGateway.{CompactionPolicy, CredentialPool, ProviderConfigs, ResponseStream}
      alias Ankole.AIGateway.Schemas.{CompactionArtifact, Message}

      :ok = CredentialPool.reset_for_test()
      config = CompactionPolicy.config()

      assert {:ok, _} =
               Ankole.AppConfigure.put_global(
                 Ankole.AIGateway.CompactionPolicy.config_definition(),
                 Map.merge(config, %{
                   "threshold" => 0.5,
                   "max_threshold_tokens" => 10,
                   "tail_rows" => 1,
                   "upstream" => upstream?
                 })
               )

      on_exit(fn ->
        Ankole.AppConfigure.delete_global(Ankole.AIGateway.CompactionPolicy.config_definition())
      end)

      {:ok, mode} = Agent.start_link(fn -> :fail end)
      on_exit(fn -> if Process.alive?(mode), do: Agent.stop(mode) end)
      test_pid = self()

      base_url =
        Ankole.AIGatewayCase.start_upstream_server(fn request ->
          cond do
            is_list(request.body["input"]) and
                List.last(request.body["input"]) == %{"type" => "compaction_trigger"} ->
              send(test_pid, :native_compacted)

              {:sse, 200,
               Ankole.AIGatewayCase.openai_compaction_stream_events("native-checkpoint", [
                 %{"type" => "compaction", "encrypted_content" => "older-history-only"}
               ])}

            request.body["model"] == "gpt-compact-light" ->
              send(test_pid, :local_compacted)

              {:sse, 200,
               Ankole.AIGatewayCase.openai_response_stream_events(
                 "summary",
                 "gpt-compact-light",
                 "## Earlier conversation\nEarlier questions and answers."
               )}

            Agent.get(mode, & &1) == :fail ->
              send(test_pid, {:failed_request, request.body})

              {:json, 400,
               %{
                 "error" => %{
                   "type" => "invalid_request_error",
                   "message" => "Injected provider open failure"
                 }
               }}

            true ->
              send(test_pid, {:successful_request, request.body})

              {:sse, 200,
               Ankole.AIGatewayCase.openai_response_stream_events(
                 "completed",
                 "gpt-main",
                 "Report received."
               )}
          end
        end)

      provider_id = "context-compaction-#{Ecto.UUID.generate()}"

      assert {:ok, _} =
               ProviderConfigs.create_provider(%{
                 provider_id: provider_id,
                 provider_kind: "openai",
                 base_url: "#{base_url}/v1",
                 credential_pool: %{"entries" => [%{"label" => "Test", "api_key" => "sk-test"}]},
                 connection_options: %{"transport" => %{}}
               })

      for {profile, model} <- [{"primary", "gpt-main"}, {"light", "gpt-compact-light"}] do
        assert {:ok, _} =
                 Ankole.AIAgent.ModelProfiles.put_model_profile(context.agent.uid, profile, %{
                   provider_id: provider_id,
                   model: model
                 })
      end

      for index <- 1..3 do
        {:ok, previous} =
          start_response_run(%{
            subject_uid: context.agent.uid,
            conversation_id: context.model_conversation_id,
            request_items: [
              %{
                "type" => "message",
                "role" => "user",
                "content" => [
                  %{"type" => "input_text", "text" => "Earlier question #{index}"}
                ]
              }
            ],
            metadata: %{
              "request_metadata" => %{
                "conversation_read" => %{
                  "id" => context.conversation.id,
                  "max_seq" => 1
                }
              }
            }
          })

        assert {:ok, _} =
                 ResponseCommit.commit_complete(previous, [], %{
                   "usage" => %{"total_tokens" => 320_004}
                 })
      end

      report =
        append_report(context, "Background report must survive failed compaction admission")

      run = context_run(context)

      request = %{
        "model" => "primary",
        "store" => true,
        "conversation" => "conv_#{context.model_conversation_id}",
        "input" => [],
        "metadata" => %{"signal_id" => run.signal_id}
      }

      first = ConversationContext.append(run, request)
      assert Ankole.JSON.encode!(first["input"]) =~ report.text
      assert {:error, _} = AIGateway.open_websocket_stream(context.agent.uid, first)
      assert_receive unquote(if upstream?, do: :native_compacted, else: :local_compacted)
      assert_receive {:failed_request, failed_request}
      assert Ankole.JSON.encode!(failed_request["input"]) =~ report.text

      failed =
        Repo.get_by!(Message, conversation_id: context.model_conversation_id, status: "error")

      checkpoint = Repo.get!(Message, failed.previous_message_id)
      assert checkpoint.type == :checkpoint
      assert checkpoint.status == :complete
      assert AIGateway.response_metadata(checkpoint) == first["metadata"]
      artifact = Repo.get!(CompactionArtifact, checkpoint.id)
      refute Ankole.JSON.encode!(artifact.content) =~ report.text

      assert ConversationContext.read_seq(
               context.agent.uid,
               context.model_conversation_id,
               context.conversation.id
             ) == 1

      Agent.update(mode, fn _ -> :success end)
      retry = ConversationContext.append(run, request)
      assert Ankole.JSON.encode!(retry["input"]) =~ report.text
      assert {:ok, stream, meta} = AIGateway.open_websocket_stream(context.agent.uid, retry)
      assert {:ok, _, _} = ResponseStream.await_terminal(stream, meta, 5_000)
      assert_receive {:successful_request, successful_request}
      assert Ankole.JSON.encode!(successful_request["input"]) =~ report.text
      assert ConversationContext.append(run, request)["input"] == []
      final_id = Ankole.AIGateway.ResponseChain.latest_visible_leaf(context.model_conversation_id)

      assert {:ok, %{status: :retracted}} =
               in_tx(fn ->
                 AIGateway.retract_visible_suffix_in_tx(
                   Repo,
                   context.agent.uid,
                   context.model_conversation_id,
                   ["resp_#{final_id}"]
                 )
               end)

      assert Ankole.JSON.encode!(ConversationContext.append(run, request)["input"]) =~ report.text
      assert AIGateway.response_metadata(Repo.reload!(checkpoint)) == first["metadata"]
    end
  end

  defp session_key(context),
    do: %{
      agent_uid: context.agent.uid,
      session_id: Ankole.Sessions.Key.conversation(context.conversation.id)
    }

  defp context_run(context) do
    %{
      agent_uid: context.agent.uid,
      session_id: Ankole.Sessions.Key.conversation(context.conversation.id),
      signal_id: Repo.get_by!(Ankole.Signals.Signal, message_id: context.first_id).id,
      steer_event_ids: [],
      conversation: %{id: context.model_conversation_id}
    }
  end

  defp append_report(context, text) do
    signal_id = Ecto.UUID.generate()

    in_tx(fn ->
      {:ok, signal} =
        Signals.accept_in_tx(Repo, %{
          producer: :kernel,
          source: "schedule:cron:context-test",
          id: signal_id,
          type: "cron.fire",
          subject: "context-test",
          target: %{agent_uid: context.agent.uid, session_id: "cron:context-test"},
          sender: context.human.uid,
          data: %{"wake_payload" => %{"cron_schedule_name" => "Context report"}}
        })

      Ankole.ConversationsFixtures.post_statement_in_tx(Repo, signal, text,
        conversation_id: context.conversation.id
      )
    end)
    |> elem(1)
    |> Map.fetch!(:messages)
    |> List.first()
  end

  defp in_tx(operation), do: Repo.transact(fn _repo -> operation.() end)
end
