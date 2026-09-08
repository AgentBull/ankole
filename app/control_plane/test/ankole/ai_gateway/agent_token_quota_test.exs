defmodule Ankole.AIGateway.AgentTokenQuotaTest do
  use Ankole.AIGatewayCase

  import ExUnit.CaptureLog

  alias Ankole.AIAgent.TokenQuota
  alias Ankole.AIGateway.Compaction
  alias Ankole.AIGateway.Schemas.UsageRecord
  alias Ankole.AIGateway.UsageLedger
  alias Ankole.Repo
  alias AnkoleWeb.AIGatewayResponsesSocket

  @completed_body %{
    "id" => "resp_quota",
    "object" => "response",
    "status" => "completed",
    "output" => [],
    "usage" => %{"input_tokens" => 120, "output_tokens" => 30}
  }

  describe "usage ledger" do
    test "a completed non-streaming Agent round records one row" do
      %{principal: agent} = agent_fixture()
      configure_openai_profile!(agent.uid, json_upstream(self()))

      assert {:ok, _response} =
               AIGateway.create_response(agent.uid, request(), subject_type: "agent")

      assert [record] = usage_records()
      assert record.subject_uid == agent.uid
      assert record.origin == "agent"
      assert record.model == "openai-token-quota/gpt-5.5"
      assert record.input_tokens == 120
      assert record.output_tokens == 30
    end

    test "a Codex client round records the codex origin" do
      %{principal: agent} = agent_fixture()
      configure_openai_profile!(agent.uid, json_upstream(self()))

      assert {:ok, _response} =
               AIGateway.create_response(agent.uid, request(),
                 subject_type: "agent",
                 request_context: %{"headers" => %{"originator" => "codex_cli_rs"}}
               )

      assert [%UsageRecord{origin: "codex"}] = usage_records()
    end

    test "an in-process round records nothing" do
      %{principal: agent} = agent_fixture()
      configure_openai_profile!(agent.uid, json_upstream(self()))

      assert {:ok, _response} = AIGateway.create_response(agent.uid, request())

      assert [] = usage_records()
    end

    test "a streaming terminal event records one row" do
      %{principal: agent} = agent_fixture()

      base_url =
        start_upstream_server(fn _request ->
          {:sse, 200,
           openai_response_stream_events("resp_stream_quota", "gpt-5.5", "hello", %{
             "input_tokens" => 7,
             "output_tokens" => 11
           })}
        end)

      configure_openai_profile!(agent.uid, base_url)

      assert {:ok, stream, _meta} =
               AIGateway.open_sse_stream(agent.uid, Map.put(request(), "stream", true),
                 subject_type: "agent"
               )

      events = collect_response_events(stream, [])
      assert "response.completed" in Enum.map(events, & &1["type"])

      assert [record] = usage_records()
      assert record.origin == "agent"
      assert record.input_tokens == 7
      assert record.output_tokens == 11
    end
  end

  describe "enforcement" do
    test "an Agent at its limit is rejected before the provider is called" do
      %{principal: agent} = agent_fixture()
      configure_openai_profile!(agent.uid, json_upstream(self()))

      assert {:ok, _quota} =
               TokenQuota.put(agent.uid, %{
                 "period_days" => 7,
                 "period_start_at" =>
                   DateTime.utc_now() |> DateTime.add(-3_600, :second) |> DateTime.to_iso8601(),
                 "limit_tokens" => 100
               })

      # The limit is soft: this round is admitted under the limit and ends above it.
      assert {:ok, _response} =
               AIGateway.create_response(agent.uid, request(), subject_type: "agent")

      assert_receive {:gateway_request, _first}

      assert {:error, {:agent_token_quota_exceeded, window}} =
               AIGateway.create_response(agent.uid, request(), subject_type: "agent")

      assert window.used_tokens == 150
      assert window.limit_tokens == 100
      assert window.exceeded

      refute_receive {:gateway_request, _blocked}
      assert length(usage_records()) == 1
    end

    test "an in-process caller is not checked against the Agent limit" do
      %{principal: agent} = agent_fixture()
      configure_openai_profile!(agent.uid, json_upstream(self()))

      assert {:ok, _quota} =
               TokenQuota.put(agent.uid, %{
                 "period_days" => 1,
                 "period_start_at" => DateTime.to_iso8601(DateTime.utc_now()),
                 "limit_tokens" => 1
               })

      assert {:ok, _response} = AIGateway.create_response(agent.uid, request())
      assert_receive {:gateway_request, _request}
    end
  end

  describe "ledger write failure" do
    test "a write that raises logs a warning and keeps the response" do
      %{principal: agent} = agent_fixture()

      runtime = %{
        "capability" => "llm",
        "subject_uid" => agent.uid,
        "provider_id" => "p",
        "model" => "m"
      }

      # A table the database cannot write makes the insert raise instead of
      # returning a changeset error, which is the failure the ledger must absorb.
      # The rename is transactional, so the sandbox rollback restores the table.
      Repo.query!(
        "ALTER TABLE ai_gateway_usage_records RENAME TO ai_gateway_usage_records_offline"
      )

      log =
        capture_log([level: :warning, metadata: [:event, :reason]], fn ->
          assert :ok = UsageLedger.record(runtime, "agent", @completed_body)
        end)

      assert log =~ "ai_gateway.usage_ledger.write_failed"
      assert log =~ "does not exist"
    end
  end

  # A compaction that an Agent-token request starts with the trigger item is
  # that request's own model work: checked and counted like the request itself.
  describe "compaction trigger" do
    setup do
      merged = Map.put(Compaction.config(), "upstream", true)
      assert {:ok, _config} = Compaction.put_config(merged)
      on_exit(fn -> Compaction.delete_config() end)
      :ok
    end

    test "an Agent at its limit is rejected before the provider is called" do
      %{principal: agent} = agent_fixture()
      configure_openai_profile!(agent.uid, json_upstream(self()))
      exhaust_quota!(agent.uid)

      assert {:error, {:agent_token_quota_exceeded, _window}} =
               AIGateway.create_response(agent.uid, trigger_request(), subject_type: "agent")

      refute_receive {:gateway_request, _blocked}
    end

    test "a Codex remote compaction round records a codex row" do
      %{principal: agent} = agent_fixture()

      base_url =
        start_upstream_server(fn _request ->
          {:sse, 200,
           openai_compaction_stream_events(
             "resp_codex_compaction",
             [%{"id" => "cmp_codex", "type" => "compaction", "encrypted_content" => "sealed"}],
             %{"input_tokens" => 60, "output_tokens" => 40, "total_tokens" => 100}
           )}
        end)

      configure_chatgpt_profile!(agent.uid, base_url)

      assert {:ok, %{body: %{"status" => "completed"}}} =
               AIGateway.create_response(agent.uid, trigger_request(),
                 subject_type: "agent",
                 request_context: %{"headers" => %{"originator" => "codex_cli_rs"}}
               )

      assert [record] = usage_records()
      assert record.origin == "codex"
      assert record.input_tokens == 60
      assert record.output_tokens == 40
    end

    test "control-plane compaction of the same conversation is not counted" do
      %{principal: agent} = agent_fixture()
      configure_openai_profile!(agent.uid, json_upstream(self()))
      exhaust_quota!(agent.uid)

      # No identity: the control plane compacts on its own behalf, so the quota
      # neither blocks it nor counts it.
      refute match?(
               {:error, {:agent_token_quota_exceeded, _window}},
               Compaction.compact_response(
                 agent.uid,
                 Map.delete(trigger_request(), "input") |> Map.put("input", history_items())
               )
             )
    end
  end

  # The Worker main turn uses the stateful WebSocket transport, so the quota
  # must reach `StatefulLifecycle` through `subject_type` like the HTTP paths.
  describe "WebSocket transport" do
    test "a stateful round records one row" do
      %{principal: agent} = agent_fixture()

      base_url =
        start_upstream_server(fn _request ->
          {:sse, 200,
           openai_response_stream_events("resp_socket_quota", "gpt-5.5", "hello", %{
             "input_tokens" => 5,
             "output_tokens" => 3
           })}
        end)

      configure_openai_profile!(agent.uid, base_url)

      assert {:ok, %{active_stream: _active} = state} =
               AIGatewayResponsesSocket.handle_in({socket_request(), [opcode: :text]}, %{
                 subject_uid: agent.uid,
                 subject_type: "agent"
               })

      refute Map.has_key?(drain_socket_stream(state), :active_stream)

      assert [record] = usage_records()
      assert record.origin == "agent"
      assert record.input_tokens == 5
      assert record.output_tokens == 3
    end

    test "an Agent at its limit receives one non-retryable error frame" do
      %{principal: agent} = agent_fixture()
      configure_openai_profile!(agent.uid, json_upstream(self()))

      assert {:ok, _quota} =
               TokenQuota.put(agent.uid, %{
                 "period_days" => 1,
                 "period_start_at" => DateTime.to_iso8601(DateTime.utc_now()),
                 "limit_tokens" => 1
               })

      Repo.insert!(
        UsageRecord.changeset(%UsageRecord{}, %{
          subject_uid: agent.uid,
          origin: "agent",
          model: "openai-token-quota/gpt-5.5",
          input_tokens: 1,
          output_tokens: 0
        })
      )

      assert {:push, {:text, pushed}, state} =
               AIGatewayResponsesSocket.handle_in({socket_request(), [opcode: :text]}, %{
                 subject_uid: agent.uid,
                 subject_type: "agent"
               })

      assert %{
               "type" => "error",
               "status" => 429,
               "headers" => %{
                 "retry-after" => _retry_after,
                 "x-codex-promo-message" => promo_message
               },
               "error" => %{
                 "code" => "agent_token_quota_exceeded",
                 "type" => "usage_limit_reached",
                 "retryable" => false,
                 "details_json" => %{"used_tokens" => 1, "limit_tokens" => 1}
               }
             } = Ankole.JSON.decode!(pushed)

      assert promo_message =~ "agent_token_quota_exceeded"
      refute Map.has_key?(state, :active_stream)
      refute_receive {:gateway_request, _blocked}
      assert length(usage_records()) == 1
    end
  end

  defp socket_request do
    Ankole.JSON.encode!(%{
      "type" => "response.create",
      "model" => "primary",
      "input" => "hello",
      "store" => true
    })
  end

  defp drain_socket_stream(state) do
    receive do
      {:ai_gateway_response_stream, _ref, :events, _events, _status} = message ->
        case AIGatewayResponsesSocket.handle_info(message, state) do
          {:push, _frames, next} -> drain_socket_stream(next)
          {:ok, next} -> drain_socket_stream(next)
        end
    after
      5_000 -> state
    end
  end

  defp request do
    %{"model" => "primary", "input" => "hello"}
  end

  defp trigger_request do
    %{"model" => "primary", "input" => history_items() ++ [%{"type" => "compaction_trigger"}]}
  end

  defp history_items do
    [
      %{"type" => "message", "role" => "user", "content" => String.duplicate("question ", 40)},
      %{"type" => "message", "role" => "assistant", "content" => String.duplicate("answer ", 40)}
    ]
  end

  defp exhaust_quota!(agent_uid) do
    assert {:ok, _quota} =
             TokenQuota.put(agent_uid, %{
               "period_days" => 1,
               "period_start_at" => DateTime.to_iso8601(DateTime.utc_now()),
               "limit_tokens" => 1
             })

    Repo.insert!(
      UsageRecord.changeset(%UsageRecord{}, %{
        subject_uid: agent_uid,
        origin: "agent",
        model: "openai-token-quota/gpt-5.5",
        input_tokens: 1,
        output_tokens: 0
      })
    )
  end

  defp configure_chatgpt_profile!(agent_uid, base_url) do
    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "chatgpt-token-quota",
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
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent_uid, "primary", %{
               provider_id: "chatgpt-token-quota",
               model: "gpt-5.5-codex"
             })
  end

  defp usage_records do
    UsageRecord |> order_by(:id) |> Repo.all()
  end

  defp json_upstream(test_pid) do
    start_upstream_server(fn request ->
      send(test_pid, {:gateway_request, request})
      {:json, 200, @completed_body}
    end)
  end

  defp configure_openai_profile!(agent_uid, base_url) do
    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-token-quota",
               provider_kind: "openai",
               base_url: "#{base_url}/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{"transport" => %{"http_versions" => ["h1"]}}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent_uid, "primary", %{
               provider_id: "openai-token-quota",
               model: "gpt-5.5"
             })
  end

  defp collect_response_events(stream, acc) do
    read_result = AIGateway.read_response_stream(stream, 1)

    receive do
      {:ai_gateway_response_stream, ref, :events, events, :continue} when ref == stream.ref ->
        collect_response_events(stream, acc ++ events)

      {:ai_gateway_response_stream, ref, :events, events, {:terminal, _outcome}}
      when ref == stream.ref ->
        acc ++ events
    after
      5_000 -> flunk("timed out waiting for the response stream after #{inspect(read_result)}")
    end
  end
end
