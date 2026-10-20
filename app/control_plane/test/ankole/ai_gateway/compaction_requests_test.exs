defmodule Ankole.AIGateway.CompactionRequestsTest do
  alias Ankole.AIGateway.ResponseCommit
  alias Ankole.AIGateway.ResponseChain
  alias Ankole.AIGateway.CompactionRequests
  alias Ankole.AIGateway.CompactionPolicy
  use Ankole.AIGatewayCase

  import Ankole.AIGateway.ResponseFixtures

  alias Ankole.AIGateway.CredentialPool

  alias Ankole.AIGateway.Compaction
  alias Ankole.AIGateway.CompactionArtifacts
  alias Ankole.AIGateway.ModelMetadata.Cache
  alias Ankole.AIGateway.StatefulLifecycle
  alias Ankole.AIGateway.Schemas.CompactionArtifact
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.Ecto.UUIDv7
  alias Ankole.Signals.Signal
  alias Ankole.Repo

  setup do
    :ok = CredentialPool.reset_for_test()
    :ok
  end

  test "ChatGPT Subscription forwards Codex v2 compaction through normal Responses" do
    %{principal: agent} = agent_fixture()

    with_compaction_config(upstream: true)

    base_url =
      start_recording_upstream(self(), fn request ->
        # Provider-native compaction is one streaming request that must carry
        # the trigger; the ChatGPT backend accepts nothing but streams.
        assert compaction_trigger_request?(request)
        assert request.body["stream"] == true

        {:sse, 200,
         openai_compaction_stream_events(
           "resp_chatgpt_v2",
           [
             %{
               "id" => "cmp_chatgpt_v2",
               "type" => "compaction",
               "encrypted_content" => "provider-opaque-state"
             }
           ],
           %{"total_tokens" => 41}
         )}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "chatgpt-v2-compaction",
               provider_kind: "chatgpt_subscription",
               base_url: base_url,
               credential_pool: %{
                 "entries" => [
                   %{
                     "id" => "enterprise",
                     "label" => "Enterprise",
                     "access_token" => "access-token",
                     "account_id" => "account-id",
                     "auth_type" => "enterprise_access_token"
                   }
                 ]
               },
               connection_options: %{"transport" => %{}}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "chatgpt-v2-compaction",
               model: "gpt-5.6-sol"
             })

    request =
      Ankole.JSON.encode!(%{
        "type" => "response.create",
        "model" => "primary",
        "input" => [
          text_message("user", "compact this history"),
          %{"type" => "compaction_trigger"}
        ]
      })

    assert {:push, pushed, _state} =
             AnkoleWeb.AIGatewayResponsesSocket.handle_in({request, [opcode: :text]}, %{
               subject_uid: agent.uid,
               subject_type: "agent",
               request_context: %{"headers" => %{"originator" => "codex_cli_rs"}}
             })

    body =
      pushed
      |> socket_frames()
      |> Enum.find(&(&1["type"] == "response.completed"))
      |> Map.fetch!("response")

    assert_receive {:gateway_request, request}
    assert request.path == "responses"

    assert [%{"type" => "compaction", "encrypted_content" => "provider-opaque-state"}] =
             body["output"]
  end

  test "websocket stateful conversation run stores checkpoint instead of projected tail as durable anchor" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-stateful-compaction-anchor",
               provider_kind: "openai",
               base_url: "http://127.0.0.1:1/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{
                 "upstream_transport" => "websocket"
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-stateful-compaction-anchor",
               model: "gpt-main"
             })

    {:ok, conversation} =
      Ankole.AIGatewayCase.ensure_conversation(agent.uid, "dispatch-compaction-anchor")

    {:ok, m1} =
      start_stateful_message(agent.uid, conversation, "compaction-anchor-a", [
        text_message("user", "first user"),
        text_message("assistant", "first assistant")
      ])

    {:ok, m1} = ResponseCommit.commit_complete(m1, [])

    {:ok, m2} =
      start_linked_stateful_message(agent.uid, conversation, m1, "compaction-anchor-b", [
        text_message("user", "second user"),
        text_message("assistant", "second assistant")
      ])

    {:ok, m2} = ResponseCommit.commit_complete(m2, [])

    {:ok, m3} =
      start_linked_stateful_message(agent.uid, conversation, m2, "compaction-anchor-c", [
        text_message("user", "third user"),
        text_message("assistant", "third assistant")
      ])

    {:ok, m3} = ResponseCommit.commit_complete(m3, [])

    {:ok, compaction} =
      insert_compaction_checkpoint(
        agent.uid,
        conversation,
        m3,
        "first turn compressed",
        m2.content ++ m3.content
      )

    assert Enum.map(ResponseChain.expand_history(conversation.id), & &1.id) == [
             compaction.id
           ]

    signal =
      signal_fixture(agent.uid, conversation.conversation_key, "compaction-anchor-d")

    current_input = [text_message("user", "fourth user")]

    assert {:error, _reason} =
             AIGateway.open_websocket_stream(agent.uid, %{
               "model" => "primary",
               "input" => current_input,
               "store" => true,
               "conversation" => "conv_#{conversation.id}",
               "metadata" => %{"signal_id" => signal.id}
             })

    [run] =
      Repo.all(Message)
      |> Enum.filter(&(get_in(&1.metadata, ["request_metadata", "signal_id"]) == signal.id))

    assert run.previous_message_id == compaction.id
    assert run.status == "error"
    assert run.content == current_input
    assert run.metadata["error"]["stage"] == "socket_open"
    assert is_nil(Repo.get!(Signal, signal.id).completed_at)
  end

  test "compaction threshold follows model context ratio with a configurable cap" do
    _result =
      Ankole.AppConfigure.delete_global(Ankole.AIGateway.CompactionPolicy.config_definition())

    assert %{
             tokens: 360_000,
             context_length: 400_000,
             effective_context_length: 400_000,
             threshold: 0.90,
             max_threshold_tokens: 400_000
           } = CompactionPolicy.threshold_spec(%{"context_length" => 400_000}, %{})

    assert %{
             tokens: 64_000,
             effective_context_length: 70_000
           } =
             CompactionPolicy.threshold_spec(%{"context_length" => 100_000}, %{
               "max_output_tokens" => 30_000
             })

    with_compaction_config(threshold: 0.25, max_threshold_tokens: 200_000, tail_rows: 2)

    assert %{
             tokens: 100_000,
             context_length: 400_000,
             threshold: 0.25,
             max_threshold_tokens: 200_000
           } = CompactionPolicy.threshold_spec(%{"context_length" => 400_000}, %{})

    assert {:error, {:unknown_compaction_config_keys, ["prefer_upstream"]}} =
             Ankole.AppConfigure.put_global(
               Ankole.AIGateway.CompactionPolicy.config_definition(),
               %{"prefer_upstream" => true}
             )
  end

  test "websocket stateful history auto-compacts through ChatGPT Subscription streaming" do
    %{principal: agent} = agent_fixture()

    with_compaction_config(threshold: 0.50, max_threshold_tokens: 10, tail_rows: 1)

    base_url =
      start_recording_upstream(self(), fn
        %{path: "models"} ->
          {:json, 200,
           %{
             "models" => [
               %{
                 "slug" => "gpt-main",
                 "visibility" => "list",
                 "supported_in_api" => true,
                 "context_window" => 256_000
               },
               %{
                 "slug" => "gpt-compact-light",
                 "visibility" => "list",
                 "supported_in_api" => true,
                 "context_window" => 400_000
               }
             ]
           }}

        %{path: "responses"} = request ->
          assert request.body["model"] == "gpt-compact-light"
          assert request.body["stream"] == true
          assert request.headers["accept"] == "text/event-stream"
          assert request.headers["session_id"] == request.body["prompt_cache_key"]

          {:sse, 200,
           openai_response_stream_events(
             "resp_summary",
             "gpt-compact-light",
             "## Active Task\nPrior two turns were compressed.",
             %{"input_tokens" => 11, "output_tokens" => 7, "total_tokens" => 18}
           )}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "chatgpt-auto-compaction",
               provider_kind: "chatgpt_subscription",
               base_url: base_url,
               credential_pool: %{
                 "entries" => [
                   %{
                     "id" => "enterprise",
                     "label" => "Enterprise",
                     "access_token" => "access-token",
                     "account_id" => "account-id",
                     "auth_type" => "enterprise_access_token"
                   }
                 ]
               },
               connection_options: %{
                 "transport" => %{}
               }
             })

    for {profile, model} <- [{"primary", "gpt-main"}, {"light", "gpt-compact-light"}] do
      assert {:ok, _profile} =
               ModelProfiles.put_model_profile(agent.uid, profile, %{
                 provider_id: "chatgpt-auto-compaction",
                 model: model
               })
    end

    {:ok, conversation} =
      Ankole.AIGatewayCase.ensure_conversation(agent.uid, "dispatch-auto-compaction")

    {:ok, m1} =
      start_stateful_message(agent.uid, conversation, "compact-a", [
        text_message("user", "first user message with enough detail"),
        text_message("assistant", "first assistant answer")
      ])

    {:ok, m1} = ResponseCommit.commit_complete(m1, [], camel_usage(160_000))

    {:ok, m2} =
      start_linked_stateful_message(agent.uid, conversation, m1, "compact-b", [
        text_message("user", "second user message with enough detail"),
        text_message("assistant", "second assistant answer")
      ])

    {:ok, m2} = ResponseCommit.commit_complete(m2, [], camel_usage(160_000))

    {:ok, m3} =
      start_linked_stateful_message(agent.uid, conversation, m2, "compact-c", [
        text_message("user", "third user message kept as tail"),
        text_message("assistant", "third assistant answer kept as tail")
      ])

    {:ok, m3} = ResponseCommit.commit_complete(m3, [], camel_usage(320_004))

    current_input = [text_message("user", "new current request")]

    assert {:ok, request, stateful_context} =
             StatefulLifecycle.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "input" => current_input,
               "store" => true,
               "conversation" => "conv_#{conversation.id}",
               "metadata" => %{"signal_id" => "auto-compact-event"}
             })

    assert_receive {:gateway_request, %{path: "models"} = models_request}
    assert models_request.method == :get
    assert_receive {:gateway_request, summarizer_request}, 1_000

    assert [
             %{
               "role" => "user",
               "content" => [%{"type" => "input_text", "text" => summarizer_input}]
             }
           ] = summarizer_request.body["input"]

    assert summarizer_request.body["model"] == "gpt-compact-light"
    assert summarizer_request.body["store"] == false
    refute Map.has_key?(summarizer_request.body, "max_output_tokens")
    assert summarizer_request.body["reasoning"] == %{"effort" => "low"}
    assert summarizer_input =~ "first user message with enough detail"
    assert summarizer_input =~ "first assistant answer"
    assert summarizer_input =~ "second user message with enough detail"
    assert summarizer_input =~ "second assistant answer"
    assert summarizer_input =~ "<recent_context_verbatim>"
    assert summarizer_input =~ "third user message kept as tail"
    assert summarizer_input =~ "third assistant answer kept as tail"
    assert summarizer_input =~ "new current request"

    [_, conversation_section] =
      Regex.run(~r/<conversation>\n(.*?)\n<\/conversation>/s, summarizer_input)

    refute conversation_section =~ "third user message kept as tail"
    refute conversation_section =~ "third assistant answer kept as tail"
    refute conversation_section =~ "new current request"

    provider_request = request.response_context.request
    [user_orig_1, user_orig_2, compaction_item | rest] = provider_request["input"]

    assert provider_request["store"] == false
    assert user_orig_1 == hd(m1.content)
    assert user_orig_2 == hd(m2.content)

    assert_local_checkpoint_message(
      compaction_item,
      "## Active Task\nPrior two turns were compressed."
    )

    assert rest == m3.content ++ current_input

    [compaction] =
      Repo.all(Message)
      |> Enum.filter(&(&1.type == "checkpoint"))

    assert compaction.previous_message_id == m3.id
    assert compaction.metadata["auto"] == true
    assert get_in(compaction.metadata, ["summarizer", "usage", "total_tokens"]) == 18

    run = stateful_context.message
    assert run.status == "generating"
    assert run.previous_message_id == compaction.id

    assert get_in(run.metadata, ["auto_compaction", "response_id"]) ==
             "resp_#{compaction.id}"

    assert %CompactionArtifact{} = artifact = Repo.get!(CompactionArtifact, compaction.id)

    assert get_in(artifact.content, ["summary", "text"]) ==
             "## Active Task\nPrior two turns were compressed."

    assert Enum.drop(artifact.content["output"], 3) == m3.content
  end

  test "websocket stateful auto-compaction keeps client-loaded tools callable" do
    %{principal: agent} = agent_fixture()

    with_compaction_config(threshold: 0.50, max_threshold_tokens: 10, tail_rows: 1)

    base_url =
      start_recording_upstream(self(), fn request ->
        assert request.path == "v1/responses"
        assert request.body["model"] == "gpt-compact-light"

        {:sse, 200,
         openai_response_stream_events(
           "resp_summary_client_tool_search",
           "gpt-compact-light",
           "## Active Task\nThe loaded calendar tool remains available."
         )}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "compatible-auto-compaction-client-tool-search",
               provider_kind: "openai_compatible",
               base_url: "#{base_url}/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-compatible"}]
               },
               connection_options: %{
                 "endpoint_kind" => "responses",
                 "transport" => %{}
               }
             })

    for {profile, model} <- [{"primary", "gpt-main"}, {"light", "gpt-compact-light"}] do
      assert {:ok, _profile} =
               ModelProfiles.put_model_profile(agent.uid, profile, %{
                 provider_id: "compatible-auto-compaction-client-tool-search",
                 model: model
               })
    end

    {:ok, conversation} =
      Ankole.AIGatewayCase.ensure_conversation(
        agent.uid,
        "dispatch-auto-compaction-client-tool-search"
      )

    loaded_tool = %{
      "type" => "function",
      "name" => "calendar",
      "description" => "Read the calendar.",
      "defer_loading" => true,
      "parameters" => %{"type" => "object", "properties" => %{}}
    }

    search_call = %{
      "type" => "tool_search_call",
      "call_id" => "search-calendar",
      "status" => "completed",
      "execution" => "client",
      "arguments" => %{"query" => "calendar"}
    }

    search_output = %{
      "type" => "tool_search_output",
      "call_id" => "search-calendar",
      "status" => "completed",
      "execution" => "client",
      "tools" => [loaded_tool]
    }

    {:ok, anchor} =
      start_stateful_message(agent.uid, conversation, "client-search-anchor", [
        text_message("user", "Load the calendar tool")
      ])

    {:ok, anchor} = ResponseCommit.commit_complete(anchor, [], camel_usage(10))

    assert {:ok, previous_checkpoint} =
             insert_compaction_checkpoint(
               agent.uid,
               conversation,
               anchor,
               "The calendar tool was loaded.",
               [search_call, search_output]
             )

    {:ok, first} =
      start_linked_stateful_message(
        agent.uid,
        conversation,
        previous_checkpoint,
        "client-search-loaded",
        [text_message("user", "Continue after the first checkpoint")]
      )

    {:ok, first} = ResponseCommit.commit_complete(first, [], camel_usage(160_000))

    {:ok, tail} =
      start_linked_stateful_message(agent.uid, conversation, first, "client-search-tail", [
        text_message("assistant", "The calendar tool is ready.")
      ])

    {:ok, tail} = ResponseCommit.commit_complete(tail, [], camel_usage(320_004))

    current_input = [text_message("user", "Use the loaded tool now")]

    assert {:ok, request, _stateful_context} =
             StatefulLifecycle.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "input" => current_input,
               "store" => true,
               "conversation" => "conv_#{conversation.id}",
               "metadata" => %{"signal_id" => "client-search-compaction-event"}
             })

    assert_receive {:gateway_request, _summarizer_request}

    provider_request = request.response_context.request
    assert Enum.map(provider_request["tools"], & &1["name"]) == ["calendar"]

    assert Enum.any?(provider_request["input"], fn
             %{"type" => "function_call", "call_id" => "search-calendar"} -> true
             _item -> false
           end)

    checkpoint =
      Repo.all(Message)
      |> Enum.find(&(&1.type == "checkpoint" and &1.previous_message_id == tail.id))

    artifact = Repo.get!(CompactionArtifact, checkpoint.id)

    assert Enum.any?(artifact.content["output"], &(&1 == search_call))
    assert Enum.any?(artifact.content["output"], &(&1 == search_output))
  end

  test "auto-compaction fits a short history by moving the preferred tail boundary forward" do
    %{principal: agent} = agent_fixture()

    with_compaction_config(threshold: 0.50, max_threshold_tokens: 45_000, tail_rows: 4)

    base_url =
      start_recording_upstream(self(), fn request ->
        assert request.path == "v1/responses"
        assert request.body["model"] == "gpt-compact-light"

        {:sse, 200,
         openai_response_stream_events(
           "resp_summary_short_history",
           "gpt-compact-light",
           "## Active Task\nThe prior report is complete."
         )}
      end)

    create_openai_compaction_provider!(agent, "short-history-compaction", base_url)

    {:ok, conversation} =
      Ankole.AIGatewayCase.ensure_conversation(agent.uid, "dispatch-short-history-compaction")

    {:ok, first} =
      start_stateful_message(agent.uid, conversation, "short-history-large", [
        text_message("assistant", String.duplicate("completed report ", 4_000))
      ])

    {:ok, first} = ResponseCommit.commit_complete(first, [], camel_usage(100_000))

    tail = text_message("assistant", "latest completed answer")

    {:ok, latest} =
      start_linked_stateful_message(agent.uid, conversation, first, "short-history-tail", [
        tail
      ])

    {:ok, latest} = ResponseCommit.commit_complete(latest, [], camel_usage(100_000))
    current_input = [text_message("user", "continue the task")]

    assert {:ok, request, _stateful_context} =
             StatefulLifecycle.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "input" => current_input,
               "store" => true,
               "conversation" => "conv_#{conversation.id}",
               "metadata" => %{"signal_id" => "short-history-next-event"}
             })

    assert_receive {:gateway_request, summarizer_request}
    assert summarizer_request.body["input"] =~ "completed report"

    [compaction] = Repo.all(Message) |> Enum.filter(&(&1.type == "checkpoint"))
    assert compaction.previous_message_id == latest.id
    assert compaction.metadata["auto"] == true
    assert compaction.metadata["covered_message_count"] == 1

    artifact = Repo.get!(CompactionArtifact, compaction.id)
    assert get_in(artifact.content, ["retention", "requested"]) == 4
    assert get_in(artifact.content, ["retention", "actual"]) == 1
    assert List.last(artifact.content["output"]) == tail

    [compaction_item | rest] = request.response_context.request["input"]

    assert_local_checkpoint_message(
      compaction_item,
      "## Active Task\nThe prior report is complete."
    )

    assert rest == [tail | current_input]
  end

  test "auto-compaction continues after a checkpoint with fewer rows than the preferred tail" do
    %{principal: agent} = agent_fixture()

    with_compaction_config(threshold: 0.50, max_threshold_tokens: 45_000, tail_rows: 4)

    base_url =
      start_recording_upstream(self(), fn request ->
        assert request.path == "v1/responses"
        assert request.body["model"] == "gpt-compact-light"

        {:sse, 200,
         openai_response_stream_events(
           "resp_summary_checkpoint_short_tail",
           "gpt-compact-light",
           "## Active Task\nProject VEGA remains active. The last answer is complete."
         )}
      end)

    create_openai_compaction_provider!(agent, "checkpoint-short-tail-compaction", base_url)

    {:ok, conversation} =
      Ankole.AIGatewayCase.ensure_conversation(agent.uid, "dispatch-checkpoint-short-tail")

    {:ok, anchor} =
      start_stateful_message(agent.uid, conversation, "checkpoint-short-tail-anchor", [
        text_message("user", "Project VEGA remains active.")
      ])

    {:ok, anchor} = ResponseCommit.commit_complete(anchor, [], camel_usage(10))

    {:ok, previous_checkpoint} =
      insert_compaction_checkpoint(
        agent.uid,
        conversation,
        anchor,
        "Project VEGA remains active.",
        []
      )

    {:ok, latest} =
      start_linked_stateful_message(
        agent.uid,
        conversation,
        previous_checkpoint,
        "checkpoint-short-tail-response",
        [text_message("user", "Continue the task"), text_message("assistant", "Answer complete")]
      )

    {:ok, latest} = ResponseCommit.commit_complete(latest, [], camel_usage(100_000))
    current_input = [text_message("user", "What project remains active?")]

    assert {:ok, request, _stateful_context} =
             StatefulLifecycle.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "input" => current_input,
               "store" => true,
               "conversation" => "conv_#{conversation.id}",
               "metadata" => %{"signal_id" => "checkpoint-short-tail-next-event"}
             })

    assert_receive {:gateway_request, summarizer_request}
    assert summarizer_request.body["input"] =~ "Project VEGA remains active."
    assert summarizer_request.body["input"] =~ "Answer complete"

    [next_checkpoint] =
      Repo.all(Message)
      |> Enum.filter(&(&1.type == "checkpoint" and &1.id != previous_checkpoint.id))

    assert next_checkpoint.previous_message_id == latest.id
    assert next_checkpoint.metadata["covered_message_count"] == 1
    artifact = Repo.get!(CompactionArtifact, next_checkpoint.id)
    assert get_in(artifact.content, ["retention", "requested"]) == 4
    assert get_in(artifact.content, ["retention", "actual"]) == 0

    assert List.last(request.response_context.request["input"]) == hd(current_input)
  end

  test "auto-compaction fits the tail after crossing another client Tool Search pair" do
    %{principal: agent} = agent_fixture()

    with_compaction_config(threshold: 0.50, max_threshold_tokens: 45_000, tail_rows: 3)

    base_url =
      start_recording_upstream(self(), fn request ->
        assert request.path == "v1/responses"
        assert request.body["model"] == "gpt-compact-light"

        {:sse, 200,
         openai_response_stream_events(
           "resp_summary_multiple_client_tool_search",
           "gpt-compact-light",
           "## Active Task\nBoth loaded tools remain available."
         )}
      end)

    create_openai_compaction_provider!(
      agent,
      "multiple-client-tool-search-compaction",
      base_url
    )

    contract_description = String.duplicate("contract ", 875)
    first_pair = client_tool_search_pair("search-a", "tool_a", contract_description)
    second_pair = client_tool_search_pair("search-b", "tool_b", contract_description)

    large_tail =
      text_message("assistant", String.duplicate("tail-body ", 1_700))

    tail_marker = text_message("assistant", "latest")

    history =
      [first_pair, second_pair, [large_tail], [tail_marker]]
      |> Enum.map(fn content ->
        %Message{
          id: UUIDv7.autogenerate(),
          type: "message",
          status: "complete",
          content: content,
          metadata: %{}
        }
      end)
      |> List.update_at(-1, &%{&1 | metadata: camel_usage(100_000)})

    assert {:ok, %{compaction: %{artifact_attrs: artifact_attrs}}} =
             Compaction.maybe_plan_history(
               agent.uid,
               UUIDv7.autogenerate(),
               history,
               [],
               %{},
               %{},
               %{"context_length" => 256_000}
             )

    retained_items = artifact_attrs.retained_items

    assert artifact_attrs.retention["actual"] == 1

    assert Enum.flat_map(retained_items, fn
             %{"type" => "tool_search_call", "call_id" => call_id} -> [call_id]
             _item -> []
           end) == ["search-a", "search-b"]

    assert List.last(retained_items) == tail_marker
    refute Enum.any?(retained_items, &(&1 == large_tail))
  end

  test "auto-compaction refit respects a cross-turn call boundary" do
    %{principal: agent} = agent_fixture()

    with_compaction_config(threshold: 0.50, max_threshold_tokens: 45_000, tail_rows: 2)

    base_url =
      start_recording_upstream(self(), fn request ->
        assert request.path == "v1/responses"
        assert request.body["model"] == "gpt-compact-light"

        {:sse, 200,
         openai_response_stream_events(
           "resp_summary_cross_turn_call_boundary",
           "gpt-compact-light",
           "## Active Task\nThe loaded tool and pending result remain available."
         )}
      end)

    create_openai_compaction_provider!(
      agent,
      "cross-turn-call-boundary-compaction",
      base_url
    )

    search_pair =
      client_tool_search_pair(
        "search-cross-turn",
        "tool_cross_turn",
        String.duplicate("contract ", 875)
      )

    large_tail = text_message("assistant", String.duplicate("tail-body ", 2_400))

    function_call = %{
      "type" => "function_call",
      "call_id" => "call-cross-turn",
      "name" => "tool_cross_turn",
      "arguments" => "{}",
      "status" => "completed"
    }

    function_output = %{
      "type" => "function_call_output",
      "call_id" => "call-cross-turn",
      "output" => "done"
    }

    history =
      [search_pair, [large_tail], [function_call]]
      |> Enum.map(fn content ->
        %Message{
          id: UUIDv7.autogenerate(),
          type: "message",
          status: "complete",
          content: content,
          metadata: %{}
        }
      end)
      |> List.update_at(-1, &%{&1 | metadata: camel_usage(100_000)})

    assert {:ok, %{compaction: %{artifact_attrs: artifact_attrs}}} =
             Compaction.maybe_plan_history(
               agent.uid,
               UUIDv7.autogenerate(),
               history,
               [function_output],
               %{},
               %{},
               %{"context_length" => 256_000}
             )

    retained_items = artifact_attrs.retained_items

    assert artifact_attrs.retention["actual"] == 1
    assert Enum.any?(retained_items, &(&1["call_id"] == "search-cross-turn"))
    assert List.last(retained_items) == function_call
    refute Enum.any?(retained_items, &(&1 == large_tail))
  end

  test "websocket stateful auto-compaction closes a complete client tool batch" do
    %{principal: agent} = agent_fixture()

    with_compaction_config(threshold: 0.50, max_threshold_tokens: 10, tail_rows: 2)

    base_url =
      start_recording_upstream(self(), fn request ->
        assert request.path == "v1/responses"
        assert request.body["model"] == "gpt-compact-light"

        {:sse, 200,
         openai_response_stream_events(
           "resp_summary_tool_tail",
           "gpt-compact-light",
           "## Active Task\nThe complete tool batch was compressed.",
           %{"input_tokens" => 7, "output_tokens" => 5, "total_tokens" => 12}
         )}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-auto-compaction-tool-tail",
               provider_kind: "openai",
               base_url: "#{base_url}/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{
                 "transport" => %{}
               }
             })

    for {profile, model} <- [{"primary", "gpt-main"}, {"light", "gpt-compact-light"}] do
      assert {:ok, _profile} =
               ModelProfiles.put_model_profile(agent.uid, profile, %{
                 provider_id: "openai-auto-compaction-tool-tail",
                 model: model
               })
    end

    {:ok, conversation} =
      Ankole.AIGatewayCase.ensure_conversation(agent.uid, "dispatch-auto-compaction-tool-tail")

    {:ok, m1} =
      start_stateful_message(agent.uid, conversation, "compact-tool-a", [
        text_message("user", "first user message that can be summarized"),
        text_message("assistant", "first assistant answer that can be summarized")
      ])

    {:ok, m1} = ResponseCommit.commit_complete(m1, [], camel_usage(160_000))

    tool_calls = [
      %{
        "type" => "function_call",
        "call_id" => "call_keep_with_tail",
        "name" => "web_search",
        "arguments" => "{}"
      },
      %{
        "type" => "custom_tool_call",
        "call_id" => "call_custom_keep_with_tail",
        "name" => "apply_patch",
        "input" => "*** Begin Patch\n*** Add File: report.md\n+done\n*** End Patch\n"
      }
    ]

    {:ok, m2} =
      start_linked_stateful_message(agent.uid, conversation, m1, "compact-tool-b", tool_calls)

    {:ok, m2} = ResponseCommit.commit_complete(m2, [], camel_usage(160_000))

    tool_results = [
      %{
        "type" => "function_call_output",
        "call_id" => "call_keep_with_tail",
        "output" => "search result"
      },
      %{
        "type" => "custom_tool_call_output",
        "call_id" => "call_custom_keep_with_tail",
        "output" => "Done!"
      }
    ]

    {:ok, m3} =
      start_linked_stateful_message(agent.uid, conversation, m2, "compact-tool-c", tool_results)

    {:ok, m3} = ResponseCommit.commit_complete(m3, [], camel_usage(320_004))

    {:ok, m4} =
      start_linked_stateful_message(agent.uid, conversation, m3, "compact-tool-d", [
        text_message("assistant", "final answer after the tool result")
      ])

    {:ok, m4} = ResponseCommit.commit_complete(m4, [], camel_usage(320_008))

    current_input = [text_message("user", "new current request")]

    assert {:ok, request, _stateful_context} =
             StatefulLifecycle.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "input" => current_input,
               "store" => true,
               "conversation" => "conv_#{conversation.id}",
               "metadata" => %{"signal_id" => "auto-compact-tool-tail-event"}
             })

    assert_receive {:gateway_request, summarizer_request}
    summarizer_input = summarizer_request.body["input"]

    assert summarizer_input =~ "first user message that can be summarized"

    [_, conversation_section] =
      Regex.run(~r/<conversation>\n(.*?)\n<\/conversation>/s, summarizer_input)

    assert conversation_section =~ "function_call web_search call_ref=call_1"
    assert conversation_section =~ "custom_tool_call apply_patch call_ref=call_2"
    assert conversation_section =~ "function_call_output call_ref=call_1 output=search result"
    assert conversation_section =~ "custom_tool_call_output call_ref=call_2 output=Done!"
    refute conversation_section =~ "call_keep_with_tail"
    refute conversation_section =~ "call_custom_keep_with_tail"

    provider_request = request.response_context.request
    [user_orig_1, compaction_item | rest] = provider_request["input"]

    assert user_orig_1 == hd(m1.content)

    assert_local_checkpoint_message(
      compaction_item,
      "## Active Task\nThe complete tool batch was compressed."
    )

    assert rest == m4.content ++ current_input

    [compaction] =
      Repo.all(Message)
      |> Enum.filter(&(&1.type == "checkpoint"))

    assert compaction.previous_message_id == m4.id
    assert compaction.metadata["auto"] == true
    assert compaction.metadata["covered_message_count"] == 3

    assert %CompactionArtifact{} = artifact = Repo.get!(CompactionArtifact, compaction.id)

    assert get_in(artifact.content, ["summary", "text"]) ==
             "## Active Task\nThe complete tool batch was compressed."

    assert Enum.drop(artifact.content["output"], 2) == m4.content
  end

  test "websocket stateful auto-compaction closes and compresses one large program batch" do
    %{principal: agent} = agent_fixture()

    with_compaction_config(threshold: 0.50, max_threshold_tokens: 160, tail_rows: 2)

    base_url =
      start_recording_upstream(self(), fn request ->
        assert request.path == "v1/responses"
        assert request.body["model"] == "gpt-compact-light"

        {:sse, 200,
         openai_response_stream_events(
           "resp_summary_program_batch",
           "gpt-compact-light",
           "## Active Task\nThe completed program batch was compressed.",
           %{"input_tokens" => 15, "output_tokens" => 9, "total_tokens" => 24}
         )}
      end)

    create_openai_compaction_provider!(
      agent,
      "openai-auto-compaction-program-batch",
      base_url
    )

    {:ok, conversation} =
      Ankole.AIGatewayCase.ensure_conversation(agent.uid, "dispatch-program-batch-compaction")

    program_call_id = "call_program_batch"
    nested_call_id = "call_program_batch_market"

    {:ok, m1} =
      start_stateful_message(agent.uid, conversation, "program-batch-call", [
        %{
          "type" => "program",
          "call_id" => program_call_id,
          "code" => "const quote = await tools.market({ symbol: \"AAPL\" }); text(quote);",
          "fingerprint" => "program-batch-fingerprint"
        },
        %{
          "type" => "function_call",
          "call_id" => nested_call_id,
          "name" => "market",
          "arguments" => ~s({"symbol":"AAPL"}),
          "caller" => %{"type" => "program", "caller_id" => program_call_id}
        }
      ])

    {:ok, m1} = ResponseCommit.commit_complete(m1, [], usage(170))

    {:ok, m2} =
      start_linked_stateful_message(agent.uid, conversation, m1, "program-batch-tool-output", [
        %{
          "type" => "function_call_output",
          "call_id" => nested_call_id,
          "output" => ~s({"price":212.5}),
          "caller" => %{"type" => "program", "caller_id" => program_call_id}
        }
      ])

    {:ok, m2} = ResponseCommit.commit_complete(m2, [], usage(175))

    large_result = "PROGRAM_RESULT_SENTINEL:" <> String.duplicate("x", 300_000)

    {:ok, m3} =
      start_linked_stateful_message(agent.uid, conversation, m2, "program-batch-output", [
        %{
          "type" => "program_output",
          "call_id" => program_call_id,
          "status" => "completed",
          "result" => large_result
        }
      ])

    {:ok, m3} = ResponseCommit.commit_complete(m3, [], usage(178))

    {:ok, m4} =
      start_linked_stateful_message(agent.uid, conversation, m3, "program-batch-final", [
        text_message(
          "assistant",
          "FINAL_RESPONSE_SENTINEL " <> String.duplicate("final ", 20_000)
        )
      ])

    {:ok, _m4} = ResponseCommit.commit_complete(m4, [], usage(180))

    current_input = [text_message("user", "continue with the result")]

    assert {:ok, request, _stateful_context} =
             StatefulLifecycle.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "input" => current_input,
               "tools" => programmatic_tools(),
               "store" => true,
               "conversation" => "conv_#{conversation.id}",
               "metadata" => %{"signal_id" => "program-batch-compaction-event"}
             })

    assert_receive {:gateway_request, summarizer_request}
    summarizer_input = Ankole.JSON.encode!(summarizer_request.body["input"])

    assert summarizer_input =~ "program call_ref=call_1"
    assert summarizer_input =~ "program_output call_ref=call_1 status=completed"
    assert summarizer_input =~ "tokens elided"
    assert summarizer_input =~ "FINAL_RESPONSE_SENTINEL"
    refute summarizer_input =~ program_call_id
    assert byte_size(summarizer_input) < 50_000

    provider_input = request.response_context.request["input"]

    assert [compaction_item | ^current_input] = provider_input

    assert_local_checkpoint_message(
      compaction_item,
      "## Active Task\nThe completed program batch was compressed."
    )

    refute Ankole.JSON.encode!(provider_input) =~ "PROGRAM_RESULT_SENTINEL"
    refute Ankole.JSON.encode!(provider_input) =~ "FINAL_RESPONSE_SENTINEL"

    [checkpoint] = Repo.all(Message) |> Enum.filter(&(&1.type == "checkpoint"))
    assert checkpoint.metadata["covered_message_count"] == 4

    assert %CompactionArtifact{} = artifact = Repo.get!(CompactionArtifact, checkpoint.id)
    assert get_in(artifact.content, ["retention", "actual"]) == 0
    assert length(artifact.content["output"]) == 1
    assert byte_size(Ankole.JSON.encode!(artifact.content["output"])) < 10_000
  end

  test "websocket stateful auto-compaction renders reasoning summaries without encrypted content" do
    %{principal: agent} = agent_fixture()

    with_compaction_config(threshold: 0.50, max_threshold_tokens: 10, tail_rows: 1)

    base_url =
      start_recording_upstream(self(), fn _request ->
        {:sse, 200,
         openai_response_stream_events(
           "resp_reasoning_summary",
           "gpt-compact-light",
           "## Active Task\nReasoning summary"
         )}
      end)

    create_openai_compaction_provider!(agent, "openai-compaction-reasoning-redaction", base_url)

    {:ok, conversation} =
      Ankole.AIGatewayCase.ensure_conversation(agent.uid, "dispatch-reasoning-redaction")

    {:ok, m1} =
      start_stateful_message(
        agent.uid,
        conversation,
        "reasoning-redaction-a",
        [
          text_message("user", "reasoning carrier"),
          %{
            "type" => "reasoning",
            "encrypted_content" => "SECRETBLOB",
            "summary" => [%{"type" => "summary_text", "text" => "thought about x"}]
          }
        ]
      )

    {:ok, m1} = ResponseCommit.commit_complete(m1, [], camel_usage(260_000))

    {:ok, m2} =
      start_linked_stateful_message(agent.uid, conversation, m1, "reasoning-redaction-tail", [
        text_message("user", "tail")
      ])

    {:ok, _m2} = ResponseCommit.commit_complete(m2, [], camel_usage(260_004))

    assert {:ok, _request, _stateful_context} =
             StatefulLifecycle.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "input" => [text_message("user", "new current request")],
               "store" => true,
               "conversation" => "conv_#{conversation.id}",
               "metadata" => %{"signal_id" => "reasoning-redaction-event"}
             })

    assert_receive {:gateway_request, summarizer_request}
    summarizer_input = summarizer_request.body["input"]
    refute summarizer_input =~ "SECRETBLOB"
    assert summarizer_input =~ "thought about x"
  end

  test "websocket stateful auto-compaction retries once with tighter render budget on context errors" do
    %{principal: agent} = agent_fixture()

    with_compaction_config(threshold: 0.50, max_threshold_tokens: 10, tail_rows: 1)
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    base_url =
      start_recording_upstream(self(), fn
        _request ->
          attempt = Agent.get_and_update(attempts, fn value -> {value + 1, value + 1} end)

          case attempt do
            1 ->
              {:json, 400, %{"error" => %{"message" => "maximum context length exceeded"}}}

            _attempt ->
              {:sse, 200,
               openai_response_stream_events(
                 "resp_retried_summary",
                 "gpt-compact-light",
                 "## Active Task\nRetried summary"
               )}
          end
      end)

    create_openai_compaction_provider!(agent, "openai-compaction-context-retry", base_url,
      profiles: [{"primary", "gpt-main", 20_000}, {"light", "gpt-compact-light", 20_000}]
    )

    {conversation, _tail} =
      compactable_conversation!(
        agent,
        "dispatch-context-retry",
        String.duplicate("wide context ", 70_000)
      )

    assert {:ok, _request, _stateful_context} =
             StatefulLifecycle.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "input" => [text_message("user", "new current request")],
               "store" => true,
               "conversation" => "conv_#{conversation.id}",
               "metadata" => %{"signal_id" => "context-retry-event"}
             })

    assert_receive {:gateway_request, first_request}
    assert_receive {:gateway_request, second_request}
    assert byte_size(second_request.body["input"]) < byte_size(first_request.body["input"])
  end

  test "websocket stateful auto-compaction skips light selector for high reasoning requests" do
    %{principal: agent} = agent_fixture()

    with_compaction_config(threshold: 0.50, max_threshold_tokens: 10, tail_rows: 1)

    base_url =
      start_recording_upstream(self(), fn request ->
        assert request.body["model"] == "gpt-main"

        {:sse, 200,
         openai_response_stream_events(
           "resp_primary_summary",
           "gpt-main",
           "## Active Task\nPrimary high reasoning summary"
         )}
      end)

    create_openai_compaction_provider!(agent, "openai-compaction-high-reasoning", base_url,
      profiles: [{"primary", "gpt-main"}]
    )

    {conversation, _tail} = compactable_conversation!(agent, "dispatch-high-reasoning")

    assert {:ok, _request, _stateful_context} =
             StatefulLifecycle.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "reasoning" => %{"effort" => "high"},
               "input" => [text_message("user", "new current request")],
               "store" => true,
               "conversation" => "conv_#{conversation.id}",
               "metadata" => %{"signal_id" => "high-reasoning-event"}
             })

    assert_receive {:gateway_request, primary_request}
    assert primary_request.body["model"] == "gpt-main"
    refute_receive {:gateway_request, _request}, 100
  end

  test "websocket stateful overflow returns an explicit error when truncation is disabled" do
    %{principal: agent} = agent_fixture()

    with_compaction_config(threshold: 0.50, max_threshold_tokens: 10, tail_rows: 1)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-overflow-disabled",
               provider_kind: "openai",
               base_url: "https://api.openai.test/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{
                 "upstream_transport" => "websocket"
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-overflow-disabled",
               model: "gpt-main"
             })

    {:ok, conversation} =
      Ankole.AIGatewayCase.ensure_conversation(agent.uid, "dispatch-overflow-disabled")

    {:ok, message} =
      start_stateful_message(agent.uid, conversation, "overflow-disabled", [
        media_message("https://files.example.test/#{String.duplicate("large", 40)}.png")
      ])

    {:ok, _message} = ResponseCommit.commit_complete(message, [], usage(24))

    assert {:error,
            {:context_overflow,
             %{
               history_usage_tokens: history_usage_tokens,
               token_threshold: 10,
               truncation: "disabled",
               reason: "no_compaction_candidate"
             }}} =
             StatefulLifecycle.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "input" => [text_message("user", "new request")],
               "store" => true,
               "conversation" => "conv_#{conversation.id}",
               "metadata" => %{"signal_id" => "overflow-disabled-event"}
             })

    assert history_usage_tokens > 10
    refute Enum.any?(Repo.all(Message), &(&1.type == "checkpoint"))
    refute_receive {:gateway_request, _request}
  end

  test "websocket stateful usage reads the latest production-shaped provider snapshot" do
    %{principal: agent} = agent_fixture()

    with_compaction_config(threshold: 0.50, max_threshold_tokens: 120_000, tail_rows: 2)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-production-usage-shape",
               provider_kind: "openai",
               base_url: "http://127.0.0.1:1/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{
                 "upstream_transport" => "websocket"
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-production-usage-shape",
               model: "gpt-main",
               context_length: 1_050_000
             })

    {:ok, conversation} =
      Ankole.AIGatewayCase.ensure_conversation(agent.uid, "dispatch-production-usage-shape")

    usage_snapshots = [
      {14_289, 177},
      {15_487, 478},
      {16_220, 936},
      {18_251, 2_940},
      {20_736, 364},
      {22_412, 160},
      {22_595, 169},
      {23_499, 264}
    ]

    anchor =
      usage_snapshots
      |> Enum.with_index()
      |> Enum.reduce(nil, fn {{input_tokens, output_tokens}, index}, previous ->
        call_id = "call_production_#{index}"

        response_items =
          if index == 6 do
            [
              text_message("assistant", "latest text")
            ]
          else
            [
              %{
                "type" => "function_call",
                "call_id" => call_id,
                "name" => "command",
                "arguments" => Ankole.JSON.encode!(%{"index" => index})
              }
            ]
          end

        {:ok, response} =
          if previous do
            start_linked_stateful_message(
              agent.uid,
              conversation,
              previous,
              "production-response-#{index}",
              response_items
            )
          else
            start_stateful_message(
              agent.uid,
              conversation,
              "production-response-#{index}",
              response_items
            )
          end

        {:ok, response} =
          ResponseCommit.commit_complete(
            response,
            [],
            provider_usage(input_tokens, output_tokens)
          )

        if index < 6 or index == 7 do
          {:ok, journal} =
            start_linked_stateful_message(
              agent.uid,
              conversation,
              response,
              "production-tool-result-#{index}",
              [
                %{
                  "type" => "function_call_output",
                  "call_id" => call_id,
                  "output" => "tool result #{index}"
                }
              ]
            )

          {:ok, journal} = ResponseCommit.commit_complete(journal, [], %{})
          journal
        else
          response
        end
      end)

    assert Enum.sum(Enum.map(usage_snapshots, fn {input, output} -> input + output end)) ==
             158_977

    assert List.last(usage_snapshots) |> then(fn {input, output} -> input + output end) ==
             23_763

    current_input = [text_message("user", "new request")]

    assert {:ok, request, _stateful_context} =
             StatefulLifecycle.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "input" => current_input,
               "store" => true,
               "previous_response_id" => "resp_#{anchor.id}",
               "metadata" => %{"signal_id" => "production-usage-shape-event"}
             })

    provider_input = request.response_context.request["input"]
    assert List.last(provider_input) == List.last(current_input)
    assert length(provider_input) == 16
    refute Enum.any?(Repo.all(Message), &(&1.type == "checkpoint"))
  end

  test "auto truncation returns context overflow for an unsettled client Tool Search call" do
    %{principal: agent} = agent_fixture()

    with_compaction_config(threshold: 0.50, max_threshold_tokens: 10, tail_rows: 1)

    history = [
      %Message{
        id: UUIDv7.autogenerate(),
        type: "message",
        status: "complete",
        content: [
          %{
            "type" => "tool_search_call",
            "call_id" => "search-unsettled",
            "status" => "completed",
            "execution" => "client",
            "arguments" => %{"query" => "calendar"}
          }
        ],
        metadata: camel_usage(20)
      },
      %Message{
        id: UUIDv7.autogenerate(),
        type: "message",
        status: "complete",
        content: [
          text_message("assistant", "latest response")
        ],
        metadata: camel_usage(20)
      }
    ]

    assert {:error,
            {:context_overflow,
             %{
               truncation: "auto",
               reason: reason
             }}} =
             Compaction.maybe_plan_history(
               agent.uid,
               UUIDv7.autogenerate(),
               history,
               [],
               %{},
               %{"truncation" => "auto"}
             )

    assert reason =~ "unsettled_tool_search_call"
  end

  test "auto truncation rejects a retained client Tool Search pair beyond the checkpoint budget" do
    %{principal: agent} = agent_fixture()

    with_compaction_config(threshold: 0.50, max_threshold_tokens: 10, tail_rows: 1)

    search_call = %{
      "type" => "tool_search_call",
      "call_id" => "search-oversized",
      "status" => "completed",
      "execution" => "client",
      "arguments" => %{"query" => "calendar"}
    }

    search_output = %{
      "type" => "tool_search_output",
      "call_id" => "search-oversized",
      "status" => "completed",
      "execution" => "client",
      "tools" => [
        %{
          "type" => "function",
          "name" => "calendar",
          "description" => String.duplicate("large contract ", 3_000),
          "defer_loading" => true,
          "parameters" => %{"type" => "object", "properties" => %{}}
        }
      ]
    }

    history = [
      %Message{
        id: UUIDv7.autogenerate(),
        type: "message",
        status: "complete",
        content: [search_call, search_output],
        metadata: camel_usage(20)
      },
      %Message{
        id: UUIDv7.autogenerate(),
        type: "message",
        status: "complete",
        content: [
          text_message("assistant", "latest response")
        ],
        metadata: camel_usage(20)
      }
    ]

    assert {:error,
            {:context_overflow,
             %{
               truncation: "auto",
               reason: "compaction_output_over_budget"
             }}} =
             Compaction.maybe_plan_history(
               agent.uid,
               UUIDv7.autogenerate(),
               history,
               [],
               %{},
               %{"truncation" => "auto"}
             )
  end

  test "websocket stateful truncation expands the stable tail for current tool output" do
    %{principal: agent} = agent_fixture()

    with_compaction_config(threshold: 0.50, max_threshold_tokens: 160, tail_rows: 1)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-truncation-stable-tail",
               provider_kind: "openai",
               base_url: "http://127.0.0.1:1/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{
                 "upstream_transport" => "websocket"
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-truncation-stable-tail",
               model: "gpt-main"
             })

    {:ok, conversation} =
      Ankole.AIGatewayCase.ensure_conversation(agent.uid, "dispatch-truncation-stable-tail")

    {:ok, call} =
      start_stateful_message(agent.uid, conversation, "stable-tail-call", [
        %{
          "type" => "function_call",
          "call_id" => "call_stable_tail",
          "name" => "lookup",
          "arguments" => Ankole.JSON.encode!(%{"query" => "stable"})
        }
      ])

    {:ok, call} = ResponseCommit.commit_complete(call, [], usage(170))

    {:ok, tail} =
      start_linked_stateful_message(agent.uid, conversation, call, "stable-tail-latest", [
        text_message("assistant", "latest response")
      ])

    {:ok, tail} = ResponseCommit.commit_complete(tail, [], usage(180))

    current_input = [
      %{
        "type" => "function_call_output",
        "call_id" => "call_stable_tail",
        "output" => "stable result"
      }
    ]

    assert {:ok, request, _stateful_context} =
             StatefulLifecycle.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "input" => current_input,
               "store" => true,
               "conversation" => "conv_#{conversation.id}",
               "truncation" => "auto",
               "metadata" => %{"signal_id" => "truncation-stable-tail-event"}
             })

    provider_request = request.response_context.request
    [compaction_item | stable_input] = provider_request["input"]

    assert_local_checkpoint_message(
      compaction_item,
      "Earlier conversation history was omitted because it exceeded the active context budget."
    )

    assert stable_input == call.content ++ tail.content ++ current_input
    assert Enum.count(Repo.all(Message), &(&1.type == "checkpoint")) == 1
  end

  test "websocket stateful truncation keeps a program call with its output" do
    %{principal: agent} = agent_fixture()

    with_compaction_config(threshold: 0.50, max_threshold_tokens: 160, tail_rows: 2)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "compatible-truncation-program-boundary",
               provider_kind: "openai_compatible",
               base_url: "http://127.0.0.1:1/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-compatible"}]
               },
               connection_options: %{
                 "endpoint_kind" => "responses"
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "compatible-truncation-program-boundary",
               model: "gpt-main"
             })

    {:ok, conversation} =
      Ankole.AIGatewayCase.ensure_conversation(agent.uid, "dispatch-truncation-program-boundary")

    {:ok, opaque} =
      start_stateful_message(agent.uid, conversation, "program-truncation-opaque", [
        media_message("https://files.example.test/program-boundary.png")
      ])

    {:ok, opaque} = ResponseCommit.commit_complete(opaque, [], usage(120))

    program_call_id = "call_program_truncation"
    nested_call_id = "call_program_truncation_market"

    {:ok, program} =
      start_linked_stateful_message(agent.uid, conversation, opaque, "program-truncation-call", [
        %{
          "type" => "program",
          "call_id" => program_call_id,
          "code" => "const quote = await tools.market({}); text(quote);",
          "fingerprint" => "program-truncation-fingerprint"
        },
        %{
          "type" => "function_call",
          "call_id" => nested_call_id,
          "name" => "market",
          "arguments" => "{}",
          "caller" => %{"type" => "program", "caller_id" => program_call_id}
        }
      ])

    {:ok, program} = ResponseCommit.commit_complete(program, [], usage(130))

    {:ok, nested_output} =
      start_linked_stateful_message(
        agent.uid,
        conversation,
        program,
        "program-truncation-nested-output",
        [
          %{
            "type" => "function_call_output",
            "call_id" => nested_call_id,
            "output" => ~s({"price":212.5}),
            "caller" => %{"type" => "program", "caller_id" => program_call_id}
          }
        ]
      )

    {:ok, nested_output} = ResponseCommit.commit_complete(nested_output, [], usage(140))

    {:ok, program_output} =
      start_linked_stateful_message(
        agent.uid,
        conversation,
        nested_output,
        "program-truncation-output",
        [
          %{
            "type" => "program_output",
            "call_id" => program_call_id,
            "status" => "completed",
            "result" => ~s({"price":212.5})
          }
        ]
      )

    {:ok, program_output} = ResponseCommit.commit_complete(program_output, [], usage(150))

    {:ok, final} =
      start_linked_stateful_message(
        agent.uid,
        conversation,
        program_output,
        "program-truncation-tail",
        [
          text_message("assistant", "program result ready")
        ]
      )

    {:ok, _final} = ResponseCommit.commit_complete(final, [], usage(180))

    current_input = [text_message("user", "use that result")]

    assert {:ok, request, _stateful_context} =
             StatefulLifecycle.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "input" => current_input,
               "tools" => programmatic_tools(),
               "store" => true,
               "conversation" => "conv_#{conversation.id}",
               "truncation" => "auto",
               "metadata" => %{"signal_id" => "program-truncation-boundary-event"}
             })

    provider_input = request.response_context.request["input"]

    program_call =
      Enum.find(
        provider_input,
        &(&1["type"] == "function_call" and &1["call_id"] == program_call_id)
      )

    settled_output =
      Enum.find(
        provider_input,
        &(&1["type"] == "function_call_output" and &1["call_id"] == program_call_id)
      )

    assert program_call["name"] == "program"
    assert settled_output["output"] =~ "completed"

    assert Enum.find_index(provider_input, &(&1 == program_call)) <
             Enum.find_index(provider_input, &(&1 == settled_output))

    refute Enum.any?(provider_input, &(&1["call_id"] == nested_call_id))
    refute Ankole.JSON.encode!(provider_input) =~ "program-boundary.png"
    assert Enum.take(provider_input, -2) == final.content ++ current_input
    refute_receive {:gateway_request, _request}
  end

  test "websocket stateful truncation keeps the compaction checkpoint with the stable tail" do
    %{principal: agent} = agent_fixture()

    with_compaction_config(threshold: 0.50, max_threshold_tokens: 160, tail_rows: 1)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-truncation-checkpoint",
               provider_kind: "openai",
               base_url: "http://127.0.0.1:1/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{
                 "upstream_transport" => "websocket"
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-truncation-checkpoint",
               model: "gpt-main"
             })

    {:ok, conversation} =
      Ankole.AIGatewayCase.ensure_conversation(agent.uid, "dispatch-truncation-checkpoint")

    {:ok, first} =
      start_stateful_message(agent.uid, conversation, "truncation-checkpoint-first", [
        text_message("user", "first user"),
        text_message("assistant", "first assistant")
      ])

    {:ok, first} = ResponseCommit.commit_complete(first, [], usage(120))

    {:ok, checkpoint} =
      insert_compaction_checkpoint(
        agent.uid,
        conversation,
        first,
        "earlier work compressed",
        first.content
      )

    {:ok, tail} =
      start_linked_stateful_message(
        agent.uid,
        conversation,
        checkpoint,
        "truncation-checkpoint-tail",
        [text_message("assistant", "latest response")]
      )

    {:ok, tail} = ResponseCommit.commit_complete(tail, [], usage(180))

    current_input = [text_message("user", "next question")]

    assert {:ok, request, %{message: run}} =
             StatefulLifecycle.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "input" => current_input,
               "store" => true,
               "conversation" => "conv_#{conversation.id}",
               "truncation" => "auto",
               "metadata" => %{"signal_id" => "truncation-checkpoint-event"}
             })

    provider_request = request.response_context.request

    assert [truncation_checkpoint, earlier_checkpoint | _rest] = provider_request["input"]

    assert_local_checkpoint_message(
      truncation_checkpoint,
      "Earlier conversation history was omitted because it exceeded the active context budget."
    )

    assert_local_checkpoint_message(earlier_checkpoint, "earlier work compressed")

    stable_tail = tail.content ++ current_input
    assert Enum.take(provider_request["input"], -length(stable_tail)) == stable_tail
    assert Enum.count(Repo.all(Message), &(&1.type == "checkpoint")) == 2

    first_truncation =
      Repo.all(Message)
      |> Enum.find(&(&1.type == "checkpoint" and &1.previous_message_id == tail.id))

    assert %Message{} = first_truncation
    assert run.previous_message_id == first_truncation.id

    {:ok, next_tail} =
      ResponseCommit.commit_complete(
        run,
        [text_message("assistant", "next response")],
        usage(190)
      )

    next_input = [text_message("user", "one more question")]

    assert {:ok, next_request, _next_context} =
             StatefulLifecycle.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "input" => next_input,
               "store" => true,
               "conversation" => "conv_#{conversation.id}",
               "truncation" => "auto",
               "metadata" => %{"signal_id" => "truncation-checkpoint-next-event"}
             })

    next_provider_input = next_request.response_context.request["input"]

    assert Enum.count(
             next_provider_input,
             &(local_checkpoint_summary(&1) ==
                 "Earlier conversation history was omitted because it exceeded the active context budget.")
           ) == 1

    assert Enum.count(
             next_provider_input,
             &(local_checkpoint_summary(&1) == "earlier work compressed")
           ) == 1

    next_stable_tail = next_tail.content ++ next_input
    assert Enum.take(next_provider_input, -length(next_stable_tail)) == next_stable_tail
    assert Enum.count(Repo.all(Message), &(&1.type == "checkpoint")) == 3
  end

  test "websocket stateful truncation checkpoints the safe tail and keeps opaque audit" do
    %{principal: agent} = agent_fixture()

    with_compaction_config(threshold: 0.50, max_threshold_tokens: 160, tail_rows: 1)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-truncation-auto",
               provider_kind: "openai",
               base_url: "http://127.0.0.1:1/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{
                 "upstream_transport" => "websocket"
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-truncation-auto",
               model: "gpt-main"
             })

    {:ok, conversation} =
      Ankole.AIGatewayCase.ensure_conversation(agent.uid, "dispatch-truncation-auto")

    media_url = "https://files.example.test/#{String.duplicate("large", 80)}.png"

    {:ok, m1} =
      start_stateful_message(agent.uid, conversation, "truncate-media", [
        media_message(media_url)
      ])

    {:ok, m1} = ResponseCommit.commit_complete(m1, [], usage(180))

    {:ok, m2} =
      start_linked_stateful_message(agent.uid, conversation, m1, "truncate-tail", [
        text_message("user", "tail user"),
        text_message("assistant", "tail assistant")
      ])

    {:ok, m2} = ResponseCommit.commit_complete(m2, [], usage(200))

    current_input = [text_message("user", "new request")]

    assert {:ok, request, stateful_context} =
             StatefulLifecycle.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "input" => current_input,
               "store" => true,
               "conversation" => "conv_#{conversation.id}",
               "truncation" => "auto",
               "metadata" => %{"signal_id" => "truncate-auto-event"}
             })

    provider_request = request.response_context.request
    [compaction_item | retained_input] = provider_request["input"]

    assert_local_checkpoint_message(
      compaction_item,
      "Earlier conversation history was omitted because it exceeded the active context budget."
    )

    assert retained_input == m2.content ++ current_input
    assert provider_request["truncation"] == "auto"
    [checkpoint] = Enum.filter(Repo.all(Message), &(&1.type == "checkpoint"))
    assert checkpoint.previous_message_id == m2.id
    refute_receive {:gateway_request, _request}

    assert %{
             "dropped_message_count" => 1,
             "dropped_opaque_message_count" => 1,
             "dropped_opaque_messages" => [
               %{
                 "message_id" => dropped_message_id,
                 "response_id" => dropped_response_id,
                 "items" => [
                   %{
                     "type" => "input_image",
                     "role" => "user",
                     "refs" => %{"image_url" => ^media_url}
                   }
                 ]
               }
             ]
           } = checkpoint.metadata["auto_truncation"]

    assert dropped_message_id == m1.id
    assert dropped_response_id == "resp_#{m1.id}"

    artifact = Repo.get!(CompactionArtifact, checkpoint.id)
    assert Enum.drop(artifact.content["output"], 1) == m2.content

    run = stateful_context.message
    assert run.status == "generating"
    assert run.previous_message_id == checkpoint.id
    assert run.content == current_input
    assert run.metadata["truncation"] == "auto"
    assert run.metadata["auto_truncation"]["response_id"] == "resp_#{checkpoint.id}"
    assert run.metadata["auto_truncation"]["dropped_message_count"] == 1
  end

  test "websocket stateful truncation auto does not start history with orphaned tool output" do
    %{principal: agent} = agent_fixture()

    with_compaction_config(threshold: 0.50, max_threshold_tokens: 220, tail_rows: 1)

    base_url =
      start_recording_upstream(self(), fn request ->
        assert request.path == "v1/responses"
        assert request.body["model"] == "gpt-main"

        {:sse, 200,
         openai_response_stream_events(
           "resp_empty_tool_summary",
           "gpt-main",
           "",
           %{"input_tokens" => 9, "output_tokens" => 0, "total_tokens" => 9}
         )}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-truncation-tool-output",
               provider_kind: "openai",
               base_url: "#{base_url}/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{
                 "transport" => %{}
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-truncation-tool-output",
               model: "gpt-main"
             })

    {:ok, conversation} =
      Ankole.AIGatewayCase.ensure_conversation(agent.uid, "dispatch-truncation-tool-output")

    {:ok, m1} =
      start_stateful_message(agent.uid, conversation, "tool-truncate-call", [
        %{
          "type" => "function_call",
          "call_id" => "call_truncated",
          "name" => "lookup",
          "arguments" => Ankole.JSON.encode!(%{"query" => String.duplicate("wide ", 120)})
        }
      ])

    {:ok, m1} = ResponseCommit.commit_complete(m1, [], usage(120))

    {:ok, m2} =
      start_linked_stateful_message(agent.uid, conversation, m1, "tool-truncate-output", [
        %{
          "type" => "function_call_output",
          "call_id" => "call_truncated",
          "output" => "tool output that must not become an orphaned prefix"
        }
      ])

    {:ok, m2} = ResponseCommit.commit_complete(m2, [], usage(120))

    {:ok, m3} =
      start_linked_stateful_message(agent.uid, conversation, m2, "tool-truncate-tail", [
        text_message("user", "latest tail")
      ])

    {:ok, _m3} = ResponseCommit.commit_complete(m3, [], usage(240))

    current_input = [text_message("user", "new request")]

    assert {:ok, request, _stateful_context} =
             StatefulLifecycle.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "input" => current_input,
               "store" => true,
               "conversation" => "conv_#{conversation.id}",
               "truncation" => "auto",
               "metadata" => %{"signal_id" => "truncate-orphan-fco-event"}
             })

    assert_receive {:gateway_request, _summarizer_request}

    provider_input = request.response_context.request["input"]
    refute Enum.any?(provider_input, &(&1 in m1.content))
    refute Enum.any?(provider_input, &(&1 in m2.content))
    assert Enum.take(provider_input, -2) == m3.content ++ current_input
  end

  test "websocket stateful truncation auto falls back when summarizer fails" do
    %{principal: agent} = agent_fixture()

    with_compaction_config(threshold: 0.50, max_threshold_tokens: 160, tail_rows: 1)

    base_url =
      start_recording_upstream(self(), fn request ->
        assert request.path == "v1/responses"
        assert request.body["model"] == "gpt-main"

        {:sse, 200,
         openai_response_stream_events(
           "resp_empty_summary",
           "gpt-main",
           "",
           %{"input_tokens" => 9, "output_tokens" => 0, "total_tokens" => 9}
         )}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-truncation-summarizer-fail",
               provider_kind: "openai",
               base_url: "#{base_url}/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{
                 "transport" => %{}
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-truncation-summarizer-fail",
               model: "gpt-main"
             })

    {:ok, conversation} =
      Ankole.AIGatewayCase.ensure_conversation(agent.uid, "dispatch-truncation-summary-fail")

    {:ok, m1} =
      start_stateful_message(agent.uid, conversation, "summary-fail-a", [
        text_message("user", String.duplicate("first ", 20))
      ])

    {:ok, m1} = ResponseCommit.commit_complete(m1, [], usage(120))

    {:ok, m2} =
      start_linked_stateful_message(agent.uid, conversation, m1, "summary-fail-b", [
        text_message("assistant", String.duplicate("second ", 20))
      ])

    {:ok, m2} = ResponseCommit.commit_complete(m2, [], usage(120))

    {:ok, m3} =
      start_linked_stateful_message(agent.uid, conversation, m2, "summary-fail-c", [
        text_message("user", "latest tail")
      ])

    {:ok, m3} = ResponseCommit.commit_complete(m3, [], usage(260))

    current_input = [text_message("user", "new request")]

    assert {:ok, request, _stateful_context} =
             StatefulLifecycle.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "input" => current_input,
               "store" => true,
               "conversation" => "conv_#{conversation.id}",
               "truncation" => "auto",
               "metadata" => %{"signal_id" => "truncate-summary-fail-event"}
             })

    assert_receive {:gateway_request, _summarizer_request}

    provider_request = request.response_context.request
    [compaction_item | _rest] = provider_request["input"]

    assert_local_checkpoint_message(
      compaction_item,
      "Earlier conversation history was omitted because it exceeded the active context budget."
    )

    refute Enum.any?(provider_request["input"], &(&1 in m1.content))
    assert Enum.take(provider_request["input"], -2) == m3.content ++ current_input

    [checkpoint] = Enum.filter(Repo.all(Message), &(&1.type == "checkpoint"))
    assert checkpoint.metadata["strategy"] == "stable_tail"
    assert checkpoint.metadata["auto_truncation"]["reason"] == "empty_compaction_summary"
    assert %CompactionArtifact{} = Repo.get!(CompactionArtifact, checkpoint.id)
  end

  test "websocket stateful truncation retries an unusable summary with the larger output cap" do
    %{principal: agent} = agent_fixture()

    with_compaction_config(threshold: 0.50, max_threshold_tokens: 160, tail_rows: 1)

    caps = start_supervised!({Agent, fn -> [] end})

    base_url =
      start_recording_upstream(self(), fn request ->
        assert request.path == "v1/responses"
        Agent.update(caps, &(&1 ++ [request.body["max_output_tokens"]]))

        summary =
          case Agent.get(caps, &length/1) do
            1 -> ""
            _retry -> "## Active Task\nRetried summary."
          end

        {:sse, 200,
         openai_response_stream_events(
           "resp_retried_summary",
           "gpt-main",
           summary,
           %{"input_tokens" => 9, "output_tokens" => 4, "total_tokens" => 13}
         )}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-unusable-summary-retry",
               provider_kind: "openai",
               base_url: "#{base_url}/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{
                 "transport" => %{}
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-unusable-summary-retry",
               model: "gpt-main"
             })

    {:ok, conversation} =
      Ankole.AIGatewayCase.ensure_conversation(agent.uid, "dispatch-unusable-summary-retry")

    {:ok, m1} =
      start_stateful_message(agent.uid, conversation, "retry-summary-a", [
        text_message("user", String.duplicate("first ", 20))
      ])

    {:ok, m1} = ResponseCommit.commit_complete(m1, [], usage(120))

    {:ok, m2} =
      start_linked_stateful_message(agent.uid, conversation, m1, "retry-summary-b", [
        text_message("assistant", String.duplicate("second ", 20))
      ])

    {:ok, m2} = ResponseCommit.commit_complete(m2, [], usage(120))

    {:ok, m3} =
      start_linked_stateful_message(agent.uid, conversation, m2, "retry-summary-c", [
        text_message("user", "latest tail")
      ])

    {:ok, _m3} = ResponseCommit.commit_complete(m3, [], usage(260))

    assert {:ok, _request, _stateful_context} =
             StatefulLifecycle.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "input" => [text_message("user", "new request")],
               "store" => true,
               "conversation" => "conv_#{conversation.id}",
               "truncation" => "auto",
               "metadata" => %{"signal_id" => "retry-summary-event"}
             })

    assert [first_cap, retry_cap] = Agent.get(caps, & &1)
    assert retry_cap > first_cap

    [checkpoint] = Enum.filter(Repo.all(Message), &(&1.type == "checkpoint"))
    refute checkpoint.metadata["strategy"] == "stable_tail"
    assert %CompactionArtifact{content: content} = Repo.get!(CompactionArtifact, checkpoint.id)
    assert content["summary"]["text"] =~ "Retried summary."
  end

  test "a stateful compaction trigger compacts the stored conversation" do
    %{principal: agent} = agent_fixture()

    with_compaction_config(threshold: 0.50, max_threshold_tokens: 160, tail_rows: 1)

    base_url =
      start_recording_upstream(self(), fn _request ->
        {:sse, 200,
         openai_response_stream_events(
           "resp_stateful_trigger",
           "gpt-main",
           "## Active Task\nstateful trigger summary",
           %{"input_tokens" => 5, "output_tokens" => 7, "total_tokens" => 12}
         )}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-stateful-trigger",
               provider_kind: "openai",
               base_url: "#{base_url}/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{
                 "transport" => %{}
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-stateful-trigger",
               model: "gpt-main"
             })

    {:ok, conversation} =
      Ankole.AIGatewayCase.ensure_conversation(agent.uid, "dispatch-stateful-trigger")

    conversation_id = conversation.id

    {:ok, m1} =
      start_stateful_message(agent.uid, conversation, "stateful-trigger-a", [
        text_message("user", String.duplicate("first ", 20))
      ])

    {:ok, m1} = ResponseCommit.commit_complete(m1, [], usage(120))

    {:ok, m2} =
      start_linked_stateful_message(agent.uid, conversation, m1, "stateful-trigger-b", [
        text_message("assistant", String.duplicate("second ", 20))
      ])

    {:ok, m2} = ResponseCommit.commit_complete(m2, [], usage(120))

    {:ok, m3} =
      start_linked_stateful_message(agent.uid, conversation, m2, "stateful-trigger-c", [
        text_message("user", "latest tail")
      ])

    {:ok, m3} = ResponseCommit.commit_complete(m3, [], usage(260))

    # The Main Agent asks for compaction through the same protocol Codex uses.
    request =
      Ankole.JSON.encode!(%{
        "type" => "response.create",
        "model" => "primary",
        "conversation" => "conv_#{conversation.id}",
        "input" => [%{"type" => "compaction_trigger"}]
      })

    assert {:push, pushed, _state} =
             AnkoleWeb.AIGatewayResponsesSocket.handle_in({request, [opcode: :text]}, %{
               subject_uid: agent.uid,
               subject_type: "agent"
             })

    body =
      pushed
      |> socket_frames()
      |> Enum.find(&(&1["type"] == "response.completed"))
      |> Map.fetch!("response")

    assert body["object"] == "response"
    assert body["status"] == "completed"
    assert [%{"type" => "compaction", "id" => "cmp_" <> artifact_id}] = body["output"]

    # A stored compaction answers with its checkpoint id so the next turn
    # continues from it.
    assert body["id"] == "resp_#{artifact_id}"

    assert %Message{type: "checkpoint", conversation_id: ^conversation_id} =
             Repo.get!(Message, artifact_id)

    assert Repo.get!(CompactionArtifact, artifact_id).content["summary"] ==
             %{"text" => "## Active Task\nstateful trigger summary"}

    # Compaction adds a checkpoint; it never deletes what it summarized. The
    # pre-compaction rows stay readable, which is what lets a later binding
    # change rebuild the history from raw predecessors.
    for original <- [m1, m2, m3] do
      assert %Message{status: "complete"} = Repo.get!(Message, original.id)
    end

    visible = ResponseChain.expand_history(conversation_id)
    assert Enum.map(visible, & &1.type) == ["checkpoint"]

    raw =
      ResponseChain.expand_history(conversation_id,
        previous_response_id: "resp_#{m3.id}",
        stop_at_checkpoint: false
      )

    assert Enum.map(raw, & &1.id) == [m1.id, m2.id, m3.id]
  end

  test "a stored compaction trigger follows its explicit anchor instead of the latest leaf" do
    %{principal: agent} = agent_fixture()
    with_compaction_config(tail_rows: 1)

    base_url =
      start_recording_upstream(self(), fn request ->
        {:sse, 200,
         openai_response_stream_events(
           "resp_explicit_compaction",
           request.body["model"],
           "## Active Task\nContinue the requested branch."
         )}
      end)

    create_openai_compaction_provider!(agent, "explicit-compaction-branch", base_url)
    {conversation, anchor} = compactable_conversation!(agent, "explicit-compaction-branch")

    {:ok, newer} =
      start_linked_stateful_message(agent.uid, conversation, anchor, "newer-branch", [
        text_message("user", "UNRELATED_NEWER_BRANCH")
      ])

    {:ok, _newer} = ResponseCommit.commit_complete(newer, [], usage(100))

    request =
      Ankole.JSON.encode!(%{
        "type" => "response.create",
        "model" => "primary",
        "store" => true,
        "previous_response_id" => "resp_#{anchor.id}",
        "input" => [%{"type" => "compaction_trigger"}]
      })

    assert {:push, pushed, _state} =
             AnkoleWeb.AIGatewayResponsesSocket.handle_in({request, [opcode: :text]}, %{
               subject_uid: agent.uid,
               subject_type: "agent"
             })

    body =
      pushed
      |> socket_frames()
      |> Enum.find(&(&1["type"] == "response.completed"))
      |> Map.fetch!("response")

    assert [%{"type" => "compaction", "id" => "cmp_" <> artifact_id}] = body["output"]
    assert body["id"] == "resp_#{artifact_id}"
    assert Repo.get!(Message, artifact_id).previous_message_id == anchor.id

    assert_receive {:gateway_request, summary_request}
    summary_input = Ankole.JSON.encode!(summary_request.body["input"])
    assert summary_input =~ "first user message"
    refute summary_input =~ "UNRELATED_NEWER_BRANCH"

    artifact = Repo.get!(CompactionArtifact, artifact_id)
    refute Ankole.JSON.encode!(artifact.content) =~ "UNRELATED_NEWER_BRANCH"
    assert Repo.get!(Message, newer.id).status == "complete"
  end

  test "a stored compaction trigger rejects an anchor from another owned conversation" do
    %{principal: agent} = agent_fixture()
    {conversation, _anchor} = compactable_conversation!(agent, "compaction-selected-conversation")

    {_other_conversation, other_anchor} =
      compactable_conversation!(agent, "compaction-other-chain")

    assert {:error, :invalid_anchor} =
             CompactionRequests.compact_from_trigger(agent.uid, %{
               "model" => "primary",
               "store" => true,
               "conversation" => "conv_#{conversation.id}",
               "previous_response_id" => "resp_#{other_anchor.id}",
               "input" => [%{"type" => "compaction_trigger"}]
             })

    assert Repo.all(CompactionArtifact) == []
    refute_receive {:gateway_request, _request}
  end

  test "the WebSocket transport answers a compaction trigger without a Provider stream" do
    %{principal: agent} = agent_fixture()

    with_compaction_config(threshold: 0.50, max_threshold_tokens: 160, tail_rows: 1)

    base_url =
      start_recording_upstream(self(), fn _request ->
        {:sse, 200,
         openai_response_stream_events(
           "resp_socket_trigger",
           "gpt-main",
           "## Active Task\nsocket trigger summary",
           %{"input_tokens" => 5, "output_tokens" => 7, "total_tokens" => 12}
         )}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-socket-trigger",
               provider_kind: "openai",
               base_url: "#{base_url}/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{
                 "transport" => %{}
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-socket-trigger",
               model: "gpt-main"
             })

    {:ok, conversation} =
      Ankole.AIGatewayCase.ensure_conversation(agent.uid, "socket-compaction-trigger")

    {:ok, m1} =
      start_stateful_message(agent.uid, conversation, "socket-trigger-a", [
        text_message("user", String.duplicate("first ", 20))
      ])

    {:ok, m1} = ResponseCommit.commit_complete(m1, [], usage(120))

    {:ok, m2} =
      start_linked_stateful_message(agent.uid, conversation, m1, "socket-trigger-b", [
        text_message("assistant", String.duplicate("second ", 20))
      ])

    {:ok, m2} = ResponseCommit.commit_complete(m2, [], usage(120))

    {:ok, m3} =
      start_linked_stateful_message(agent.uid, conversation, m2, "socket-trigger-c", [
        text_message("user", "latest tail")
      ])

    {:ok, _m3} = ResponseCommit.commit_complete(m3, [], usage(260))

    request =
      Ankole.JSON.encode!(%{
        "type" => "response.create",
        "model" => "primary",
        "conversation" => "conv_#{conversation.id}",
        "input" => [%{"type" => "compaction_trigger"}]
      })

    assert {:push, pushed, state} =
             AnkoleWeb.AIGatewayResponsesSocket.handle_in({request, [opcode: :text]}, %{
               subject_uid: agent.uid,
               subject_type: "agent"
             })

    # The trigger never opens a Provider stream, so no active stream survives it.
    refute Map.has_key?(state, :active_stream)

    events = Enum.map(pushed, fn {:text, chunk} -> Ankole.JSON.decode!(chunk) end)

    assert [
             "response.created",
             "response.output_item.added",
             "response.output_item.done",
             "response.completed"
           ] = Enum.map(events, & &1["type"])

    assert Enum.map(events, & &1["sequence_number"]) == [0, 1, 2, 3]

    assert [%{"item" => %{"type" => "compaction", "id" => "cmp_" <> artifact_id}} | _] =
             Enum.filter(events, &(&1["type"] == "response.output_item.done"))

    assert List.last(events)["response"]["id"] == "resp_#{artifact_id}"
    assert %Message{type: "checkpoint"} = Repo.get!(Message, artifact_id)
  end

  test "local standalone compact uses the request model context budget" do
    %{principal: agent} = agent_fixture()

    with_compaction_config(threshold: 0.50, max_threshold_tokens: 100_000, tail_rows: 1)

    base_url =
      start_recording_upstream(self(), fn request ->
        assert request.path == "v1/responses"
        assert request.body["model"] == "gpt-compact-light"

        {:sse, 200,
         openai_response_stream_events(
           "resp_summary_standalone_context_budget",
           "gpt-compact-light",
           "## Active Task\nThe large loaded contract remains active."
         )}
      end)

    create_openai_compaction_provider!(
      agent,
      "standalone-context-budget",
      base_url,
      profiles: [
        {"primary", "gpt-main", 131_072},
        {"light", "gpt-compact-light", 131_072}
      ]
    )

    oversized_pair =
      client_tool_search_pair(
        "search-oversized-context",
        "large_contract",
        String.duplicate("x", 270_000)
      )

    assert {:error, :compaction_output_over_budget} =
             CompactionRequests.compact_response(agent.uid, %{
               "model" => "primary",
               "input" => oversized_pair,
               "store" => false
             })

    assert_receive {:gateway_request, %{path: "v1/responses"}}
    refute_receive {:gateway_request, %{path: "v1/responses"}}, 100
    assert Repo.all(CompactionArtifact) == []
  end

  for path <- [:automatic, :manual],
      fallback <- [:binding_change, :upstream_disabled, :provider_fallback] do
    @tag compaction_path: path, native_fallback: fallback
    test "#{path} compaction rebuilds native history after #{fallback}", %{
      compaction_path: path,
      native_fallback: fallback
    } do
      %{principal: agent} = agent_fixture()
      prefer_provider_compaction!(agent.uid)
      # The history here is a few items, so the retained tail must be pinned below
      # it; this test is about replacing native output, not about the row floor.
      with_compaction_config(threshold: 0.50, max_threshold_tokens: 10, tail_rows: 1)

      native_output = [
        %{"type" => "message", "role" => "user", "content" => "provider-retained"},
        %{
          "type" => "compaction",
          "encrypted_content" => "provider-opaque-state",
          "provider_extension" => %{"preserve" => true}
        }
      ]

      native_requests = start_supervised!({Agent, fn -> 0 end})

      base_url =
        start_recording_upstream(self(), fn request ->
          if compaction_trigger_request?(request) do
            attempt = Agent.get_and_update(native_requests, &{&1 + 1, &1 + 1})

            if fallback == :provider_fallback and attempt > 1 do
              {:json, 404, %{"error" => %{"message" => "Compaction is unsupported."}}}
            else
              {:sse, 200,
               openai_compaction_stream_events("resp_native_stateful", native_output, %{
                 "total_tokens" => 41
               })}
            end
          else
            {:sse, 200,
             openai_response_stream_events(
               "resp_binding_fallback_summary",
               request.body["model"],
               "## Active Task\nRebuilt from the raw predecessor chain."
             )}
          end
        end)

      create_openai_compaction_provider!(agent, "openai-native-stateful", base_url)

      {conversation, _tail} =
        compactable_conversation!(agent, "native-stateful", "RAW_PREDECESSOR_ONLY")

      conversation = seed_checkpoint_memory!(agent, conversation, "memory-native-rebuild")

      first_input = [
        text_message("user", "continue discussing Wire Format after native compaction")
      ]

      first_event = signal_fixture(agent.uid, conversation.conversation_key, "native-first")

      assert {:ok, first_request, first_context} =
               StatefulLifecycle.prepare_websocket_request(agent.uid, %{
                 "model" => "primary",
                 "input" => first_input,
                 "store" => true,
                 "conversation" => "conv_#{conversation.id}",
                 "metadata" => %{"signal_id" => first_event.id}
               })

      assert_receive {:gateway_request, %{path: "v1/responses"}}
      replayed_input = first_request.response_context.request["input"]
      assert Enum.any?(replayed_input, &(Map.get(&1, "type") == "compaction"))
      assert Enum.take(replayed_input, -length(first_input)) == first_input

      assert {:ok, _completed} =
               ResponseCommit.commit_complete(
                 first_context.message,
                 [text_message("assistant", "native continuation complete")],
                 camel_usage(320_010)
               )

      case fallback do
        :binding_change ->
          assert {:ok, _profile} =
                   ModelProfiles.put_model_profile(agent.uid, "primary", %{
                     provider_id: "openai-native-stateful",
                     model: "gpt-main-rebound"
                   })

        :upstream_disabled ->
          with_compaction_config(upstream: false)

        :provider_fallback ->
          :ok
      end

      visible_anchor = "resp_#{first_context.message.id}"

      case path do
        :automatic ->
          second_input = [
            text_message("user", "continue discussing Wire Format after native rebuild")
          ]

          second_event =
            signal_fixture(agent.uid, conversation.conversation_key, "native-rebound")

          assert {:ok, second_request, _second_context} =
                   StatefulLifecycle.prepare_websocket_request(agent.uid, %{
                     "model" => "primary",
                     "input" => second_input,
                     "store" => true,
                     "conversation" => "conv_#{conversation.id}",
                     "metadata" => %{"signal_id" => second_event.id}
                   })

          second_provider_input = second_request.response_context.request["input"]
          refute Ankole.JSON.encode!(second_provider_input) =~ "provider-opaque-state"
          assert Enum.any?(second_provider_input, &local_checkpoint_summary/1)
          assert Enum.take(second_provider_input, -length(second_input)) == second_input

        :manual ->
          assert {:ok, %{compaction: checkpoint}} =
                   CompactionRequests.compact_conversation(agent.uid, conversation.id, %{
                     "previous_response_id" => visible_anchor
                   })

          assert checkpoint.previous_message_id == first_context.message.id
      end

      if fallback == :provider_fallback do
        assert_receive {:gateway_request, rejected}
        assert compaction_trigger_request?(rejected)
      end

      assert_receive {:gateway_request, summary_request}
      refute compaction_trigger_request?(summary_request)
      summary_input = Ankole.JSON.encode!(summary_request.body["input"])
      assert summary_input =~ "RAW_PREDECESSOR_ONLY"
      refute summary_input =~ "provider-opaque-state"
      refute_receive {:gateway_request, %{path: "v1/responses"}}, 100

      artifacts =
        Repo.all(CompactionArtifact)
        |> Enum.filter(&(&1.conversation_id == conversation.id))
        |> Enum.sort_by(& &1.inserted_at, DateTime)

      assert Enum.map(artifacts, & &1.content["version"]) == [3, 2]
      local = List.last(artifacts)
      assert [pack] = local.content["brain_context_pack"]
      assert Ankole.JSON.encode!(pack) =~ "MEMORY_ORION"
      assert Repo.get!(Message, local.id).previous_message_id == first_context.message.id

      assert Agent.get(native_requests, & &1) ==
               if(fallback == :provider_fallback, do: 2, else: 1)
    end
  end

  test "manual conversation compaction uses the same upstream selector" do
    %{principal: agent} = agent_fixture()
    prefer_provider_compaction!(agent.uid)

    native_output = [
      %{"type" => "compaction", "encrypted_content" => "manual-provider-state"}
    ]

    base_url =
      start_recording_upstream(self(), fn request ->
        assert request.path == "v1/responses"
        refute Ankole.JSON.encode!(request.body) =~ "MEMORY_ORION"
        assert List.last(request.body["input"]) == %{"type" => "compaction_trigger"}
        {:sse, 200, openai_compaction_stream_events("resp_native_manual", native_output)}
      end)

    create_openai_compaction_provider!(agent, "openai-native-manual", base_url,
      profiles: [{"primary", "gpt-main"}]
    )

    {conversation, tail} = compactable_conversation!(agent, "native-manual")

    conversation = seed_checkpoint_memory!(agent, conversation, "memory-manual-native")

    assert {:ok, %{compaction: checkpoint}} =
             CompactionRequests.compact_conversation(agent.uid, conversation.id)

    assert_receive {:gateway_request, %{path: "v1/responses"}}
    assert checkpoint.previous_message_id == tail.id

    artifact = Repo.get!(CompactionArtifact, checkpoint.id)
    assert artifact.content["version"] == 3
    assert artifact.content["output"] == native_output
    assert [_pack] = artifact.content["brain_context_pack"]
  end

  for status <- [404, 405] do
    test "standalone compact caches a stable unsupported #{status} response" do
      status = unquote(status)
      %{principal: agent} = agent_fixture()
      prefer_provider_compaction!(agent.uid)
      :ok = Cache.clear_for_test()
      {:ok, compact_attempts} = Agent.start_link(fn -> 0 end)

      base_url =
        start_recording_upstream(self(), fn request ->
          if compaction_trigger_request?(request) do
            Agent.update(compact_attempts, &(&1 + 1))
            {:json, status, %{"error" => %{"code" => "not_found"}}}
          else
            {:sse, 200,
             openai_response_stream_events(
               "resp_local_summary",
               "gpt-5.6",
               "## Active Task\nLocal fallback summary"
             )}
          end
        end)

      configure_openai_responses_provider!(
        agent.uid,
        base_url,
        "openai-native-compact-negative-cache-#{status}"
      )

      request = %{"model" => "primary", "input" => [text_message("user", "history")]}

      assert {:ok, _body} = CompactionRequests.compact_response(agent.uid, request)
      assert {:ok, _body} = CompactionRequests.compact_response(agent.uid, request)
      assert Agent.get(compact_attempts, & &1) == 1

      assert {:ok, _profile} =
               ModelProfiles.put_model_profile(agent.uid, "primary", %{
                 provider_id: "openai-native-compact-negative-cache-#{status}",
                 model: "gpt-5.6-revision"
               })

      assert {:ok, _body} = CompactionRequests.compact_response(agent.uid, request)
      assert Agent.get(compact_attempts, & &1) == 2
    end
  end

  for status <- [500, 503] do
    test "standalone compact does not cache a transient #{status} provider failure" do
      status = unquote(status)
      %{principal: agent} = agent_fixture()
      prefer_provider_compaction!(agent.uid)
      :ok = Cache.clear_for_test()
      {:ok, compact_attempts} = Agent.start_link(fn -> 0 end)

      base_url =
        start_recording_upstream(self(), fn request ->
          if compaction_trigger_request?(request) do
            Agent.update(compact_attempts, &(&1 + 1))
            {:json, status, %{"error" => %{"code" => "provider_unavailable"}}}
          else
            {:sse, 200,
             openai_response_stream_events(
               "resp_local_summary",
               "gpt-5.6",
               "## Active Task\nLocal fallback summary"
             )}
          end
        end)

      configure_openai_responses_provider!(
        agent.uid,
        base_url,
        "openai-native-compact-transient-#{status}"
      )

      request = %{"model" => "primary", "input" => [text_message("user", "history")]}

      assert {:ok, _body} = CompactionRequests.compact_response(agent.uid, request)
      attempts_after_first_request = Agent.get(compact_attempts, & &1)
      assert attempts_after_first_request > 0

      assert {:ok, _body} = CompactionRequests.compact_response(agent.uid, request)
      assert Agent.get(compact_attempts, & &1) > attempts_after_first_request
    end
  end

  test "standalone compact with only opaque provider state reports no candidate" do
    %{principal: agent} = agent_fixture()

    configure_openai_responses_provider!(
      agent.uid,
      "http://127.0.0.1:1",
      "openai-native-compact-opaque"
    )

    assert {:error, :no_compaction_candidate} =
             CompactionRequests.compact_response(agent.uid, %{
               "model" => "primary",
               "input" => [
                 %{"type" => "compaction", "encrypted_content" => "provider-opaque-state"}
               ]
             })
  end

  test "standalone compact preserves opaque provider state through the local fallback" do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn _request ->
        {:sse, 200,
         openai_response_stream_events(
           "resp_opaque_summary",
           "gpt-5.6",
           "## Active Task\nSummary of the work after the provider state"
         )}
      end)

    configure_openai_responses_provider!(agent.uid, base_url, "openai-opaque-preserved")

    retained_message = %{
      "type" => "message",
      "role" => "user",
      "content" => "provider-retained"
    }

    opaque_item = %{"type" => "compaction", "encrypted_content" => "provider-opaque-state"}

    assert {:ok, body} =
             CompactionRequests.compact_response(agent.uid, %{
               "model" => "primary",
               "input" => [
                 retained_message,
                 opaque_item,
                 text_message("user", "post-compaction work to summarize")
               ]
             })

    # The reply keeps exactly one compaction item, and the opaque provider
    # state never leaks into the reply output.
    assert [%{"type" => "compaction", "encrypted_content" => "ankole:compact:v1:" <> _}] =
             Enum.filter(body["output"], &(&1["type"] == "compaction"))

    refute Ankole.JSON.encode!(body["output"]) =~ "provider-opaque-state"

    assert [artifact] = Repo.all(CompactionArtifact)
    assert artifact.content["version"] == 2
    assert artifact.content["opaque_prefix"] == [retained_message, opaque_item]
    assert artifact.content["retention"]["opaque_prefix_items"] == 2

    # Handle resolution replays the preserved provider state ahead of the
    # local checkpoint text.
    assert {:ok, resolved} =
             CompactionArtifacts.resolve_input_handles(agent.uid, [
               CompactionArtifacts.compaction_item(artifact.id)
             ])

    assert [^retained_message, ^opaque_item, checkpoint_message] = resolved
    assert checkpoint_message["type"] == "message"
    assert checkpoint_message["role"] == "user"

    assert [%{"text" => checkpoint_text}] = checkpoint_message["content"]
    assert checkpoint_text =~ "Summary of the work after the provider state"
  end

  test "provider compaction falls back locally for a connection without official OpenAI tool support" do
    %{principal: agent} = agent_fixture()
    prefer_provider_compaction!(agent.uid)

    base_url =
      start_recording_upstream(self(), fn request ->
        refute compaction_trigger_request?(request)

        {:sse, 200,
         openai_response_stream_events(
           "resp_local_summary",
           request.body["model"],
           "## Active Task\nSummarized locally."
         )}
      end)

    configure_openai_compatible_responses_provider!(
      agent.uid,
      base_url,
      "compatible-compact-gate-off"
    )

    assert {:ok, body} =
             CompactionRequests.compact_response(agent.uid, %{
               "model" => "primary",
               "input" => [text_message("user", "compact this history")],
               "store" => false
             })

    assert_receive {:gateway_request, request}
    refute compaction_trigger_request?(request)
    assert Enum.any?(body["output"], &(&1["type"] == "compaction"))
  end

  test "provider compaction reaches a connection that declares official OpenAI tool support" do
    %{principal: agent} = agent_fixture()
    prefer_provider_compaction!(agent.uid)

    native_output = [
      %{"type" => "compaction", "encrypted_content" => "provider-opaque-state"}
    ]

    base_url =
      start_recording_upstream(self(), fn request ->
        assert compaction_trigger_request?(request)

        {:sse, 200,
         openai_compaction_stream_events("resp_native_compat", native_output, %{
           "total_tokens" => 7
         })}
      end)

    configure_openai_compatible_responses_provider!(
      agent.uid,
      base_url,
      "compatible-compact-gate-on",
      %{"supports_openai_tools" => true}
    )

    assert {:ok, body} =
             CompactionRequests.compact_response(agent.uid, %{
               "model" => "primary",
               "input" => [text_message("user", "compact this history")],
               "store" => false
             })

    assert_receive {:gateway_request, request}
    assert compaction_trigger_request?(request)
    assert body["output"] == native_output
  end

  defp compactable_conversation!(agent, conversation_key, extra_text \\ "") do
    {:ok, conversation} = Ankole.AIGatewayCase.ensure_conversation(agent.uid, conversation_key)

    {:ok, m1} =
      start_stateful_message(agent.uid, conversation, "#{conversation_key}-a", [
        text_message(
          "user",
          "first user message with enough detail " <> String.duplicate("wide ", 80)
        ),
        text_message("assistant", "first assistant answer " <> extra_text)
      ])

    {:ok, m1} = ResponseCommit.commit_complete(m1, [], camel_usage(160_000))

    {:ok, m2} =
      start_linked_stateful_message(agent.uid, conversation, m1, "#{conversation_key}-b", [
        text_message("user", "second user message with enough detail"),
        text_message("assistant", "second assistant answer " <> extra_text)
      ])

    {:ok, m2} = ResponseCommit.commit_complete(m2, [], camel_usage(160_000))

    {:ok, m3} =
      start_linked_stateful_message(agent.uid, conversation, m2, "#{conversation_key}-tail", [
        text_message("user", "tail user says stop doing X")
      ])

    {:ok, m3} = ResponseCommit.commit_complete(m3, [], camel_usage(320_004))

    {conversation, m3}
  end

  defp client_tool_search_pair(call_id, tool_name, description) do
    tool = %{
      "type" => "function",
      "name" => tool_name,
      "description" => description,
      "defer_loading" => true,
      "parameters" => %{"type" => "object", "properties" => %{}}
    }

    [
      %{
        "type" => "tool_search_call",
        "call_id" => call_id,
        "status" => "completed",
        "execution" => "client",
        "arguments" => %{"query" => tool_name}
      },
      %{
        "type" => "tool_search_output",
        "call_id" => call_id,
        "status" => "completed",
        "execution" => "client",
        "tools" => [tool]
      }
    ]
  end

  defp media_message(image_url) do
    %{
      "type" => "message",
      "role" => "user",
      "content" => [%{"type" => "input_image", "image_url" => image_url}]
    }
  end

  defp camel_usage(total_tokens), do: %{"usage" => %{"totalTokens" => total_tokens}}

  defp provider_usage(input_tokens, output_tokens) do
    %{
      "usage" => %{
        "input_tokens" => input_tokens,
        "output_tokens" => output_tokens,
        "total_tokens" => input_tokens + output_tokens
      }
    }
  end

  # The compaction trigger and a normal turn share one path, so a Provider tells
  # them apart by the trigger item, not by the endpoint.
  defp socket_frames({:text, chunk}), do: [Ankole.JSON.decode!(chunk)]

  defp socket_frames(chunks),
    do: Enum.map(chunks, fn {:text, chunk} -> Ankole.JSON.decode!(chunk) end)

  defp compaction_trigger_request?(request) do
    case request.body["input"] do
      input when is_list(input) -> List.last(input) == %{"type" => "compaction_trigger"}
      _other -> false
    end
  end

  defp assert_local_checkpoint_message(item, summary) do
    assert local_checkpoint_summary(item) == summary
  end

  defp insert_compaction_checkpoint(
         agent_uid,
         conversation,
         previous_message,
         summary_text,
         retained_items,
         metadata \\ %{}
       ) do
    with {:ok, artifact} <-
           CompactionArtifacts.insert_artifact(%{
             subject_uid: agent_uid,
             conversation_id: conversation.id,
             summary_text: summary_text,
             retained_items: retained_items,
             retention: %{
               "strategy" => "tail_rows",
               "requested" => 2,
               "actual" => length(retained_items)
             },
             usage: %{}
           }) do
      ResponseChain.create_compaction_checkpoint(%{
        subject_uid: agent_uid,
        previous_response_id: "resp_#{previous_message.id}",
        artifact: artifact,
        metadata: metadata
      })
    end
  end
end
