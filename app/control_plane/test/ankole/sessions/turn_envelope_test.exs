defmodule Ankole.Sessions.TurnEnvelopeTest do
  use Ankole.DataCase, async: false

  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.Signals.Signal
  alias Ankole.Sessions.TurnEnvelope
  alias Ankole.Sessions.JobTurnRef

  setup do
    allow_cache_database_access()
    :ok
  end

  test "projects the declared hosted tools in policy order" do
    envelope =
      turn_start(%{
        model_ref: model_ref(),
        request_context: %{},
        hosted_tools: [%{"type" => "image_generation"}, %{"type" => "web_search"}]
      })

    assert %FabricProto.Envelope{body: {:turn_start, turn_start}} = envelope

    assert turn_start.hosted_tools == [:HOSTED_TOOL_IMAGE_GENERATION, :HOSTED_TOOL_WEB_SEARCH]
  end

  test "maps the stored brain projection to its enum" do
    assert {:ok, spec} =
             Ankole.BackgroundAgentJobs.RuntimeProjection.turn_start_overrides(%{
               "version" => 1,
               "model_ref" => model_ref(),
               "runtime_policy" => %{},
               "hosted_tools" => [%{"type" => "brain"}]
             })

    assert %FabricProto.Envelope{body: {:turn_start, %{hosted_tools: [:HOSTED_TOOL_BRAIN]}}} =
             turn_start(spec)
  end

  test "rejects unsupported and duplicate hosted tools" do
    spec = fn hosted_tools ->
      %{
        model_ref: model_ref(),
        request_context: %{},
        hosted_tools: hosted_tools
      }
    end

    assert_raise ArgumentError, ~r/unsupported turn hosted tool/, fn ->
      turn_start(spec.([%{"type" => "computer_use"}]))
    end

    assert_raise ArgumentError, ~r/duplicate turn hosted tools/, fn ->
      turn_start(spec.([%{"type" => "web_search"}, %{"type" => "web_search"}]))
    end

    assert_raise ArgumentError, ~r/invalid turn hosted tools/, fn ->
      turn_start(spec.([]))
    end
  end

  test "omits hosted tools when the turn policy did not declare one" do
    envelope =
      turn_start(%{
        model_ref: model_ref(),
        request_context: %{}
      })

    assert %FabricProto.Envelope{body: {:turn_start, turn_start}} = envelope
    assert turn_start.hosted_tools == []
  end

  test "carries trusted turn runtime environment values" do
    envelope =
      turn_start(%{
        model_ref: model_ref(),
        request_context: %{},
        runtime_env: %{"ANKOLE_RUNTIME_CURRENT_ACTOR_SENDER_PRINCIPAL" => "human-alice"}
      })

    assert %FabricProto.Envelope{body: {:turn_start, turn_start}} = envelope

    assert turn_start.runtime_env == %{
             "ANKOLE_RUNTIME_CURRENT_ACTOR_SENDER_PRINCIPAL" => "human-alice"
           }
  end

  test "pushes the current fetch policy to the Job" do
    {:ok, _} = Ankole.AppConfigure.put_global(Ankole.Security.SSRFFilter.definition(), true)

    {:ok, _} =
      Ankole.AppConfigure.put_tenant_by_key("worker.rendered_fetch_idle_ttl_ms", 600_000)

    assert %FabricProto.Envelope{body: {:turn_start, start}} = turn_start(%{})

    assert start.fetch_runtime_config == %FabricProto.FetchRuntimeConfig{
             ssrf_filter: true,
             rendered_fetch_idle_ttl_ms: 600_000
           }
  end

  defp turn_start(spec) do
    %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
    TurnEnvelope.turn_start(turn_ref(agent.uid), signal(), spec, "start", nil)
  end

  defp turn_ref(agent_uid) do
    %JobTurnRef{
      agent_uid: agent_uid,
      session_id: "job:1000",
      job_id: 1000,
      attempt: 1,
      signal_id: "019f7057-5fd2-76d0-a553-c6c84da72b43"
    }
  end

  defp signal do
    %Signal{
      producer: :kernel,
      id: "019f7057-5fd2-76d0-a553-c6c84da72b43",
      queue_sequence: 1,
      type: "conversation.message.addressed",
      source: "test:turn-envelope",
      occurred_at: DateTime.utc_now(:microsecond),
      source_event_id: "source-test",
      data: %{}
    }
  end

  defp model_ref do
    %{
      "profile" => "primary",
      "provider_id" => "openrouter-main",
      "provider_kind" => "openrouter",
      "model" => "openai/gpt-4o-mini",
      "input_modalities" => ["text"]
    }
  end
end
