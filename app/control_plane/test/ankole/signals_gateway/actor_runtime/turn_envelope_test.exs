defmodule Ankole.SignalsGateway.ActorRuntime.TurnEnvelopeTest do
  use ExUnit.Case, async: true

  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ActorRuntime.TurnEnvelope
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef

  test "projects the declared hosted tools in policy order" do
    envelope =
      TurnEnvelope.turn_start(turn_ref(), actor_event(), [], %{
        workspace_id: 10_000,
        model_ref: model_ref(),
        request_context: %{},
        hosted_tools: [%{"type" => "image_generation"}, %{"type" => "web_search"}]
      })

    assert %FabricProto.Envelope{body: {:turn_start, turn_start}} = envelope

    assert Torque.decode!(turn_start.hosted_tools_json) == [
             %{"type" => "image_generation"},
             %{"type" => "web_search"}
           ]
  end

  test "rejects unsupported and duplicate hosted tools" do
    spec = fn hosted_tools ->
      %{
        workspace_id: 10_000,
        model_ref: model_ref(),
        request_context: %{},
        hosted_tools: hosted_tools
      }
    end

    assert_raise ArgumentError, ~r/unsupported turn hosted tool/, fn ->
      TurnEnvelope.turn_start(turn_ref(), actor_event(), [], spec.([%{"type" => "computer_use"}]))
    end

    assert_raise ArgumentError, ~r/duplicate turn hosted tools/, fn ->
      TurnEnvelope.turn_start(
        turn_ref(),
        actor_event(),
        [],
        spec.([%{"type" => "web_search"}, %{"type" => "web_search"}])
      )
    end

    assert_raise ArgumentError, ~r/invalid turn hosted tools/, fn ->
      TurnEnvelope.turn_start(turn_ref(), actor_event(), [], spec.([]))
    end
  end

  test "omits hosted tools when the turn policy did not declare one" do
    envelope =
      TurnEnvelope.turn_start(turn_ref(), actor_event(), [], %{
        workspace_id: 10_000,
        model_ref: model_ref(),
        request_context: %{}
      })

    assert %FabricProto.Envelope{body: {:turn_start, turn_start}} = envelope
    assert turn_start.hosted_tools_json == ""
  end

  test "carries the model output-token ceiling as a typed field" do
    envelope =
      TurnEnvelope.turn_start(turn_ref(), actor_event(), [], %{
        workspace_id: 10_000,
        model_ref: Map.put(model_ref(), "max_completion_tokens", 32_000),
        request_context: %{}
      })

    assert %FabricProto.Envelope{body: {:turn_start, turn_start}} = envelope
    assert turn_start.model_ref.max_completion_tokens == 32_000

    without_limit =
      TurnEnvelope.turn_start(turn_ref(), actor_event(), [], %{
        workspace_id: 10_000,
        model_ref: model_ref(),
        request_context: %{}
      })

    assert %FabricProto.Envelope{body: {:turn_start, no_limit_start}} = without_limit
    assert no_limit_start.model_ref.max_completion_tokens == nil
  end

  test "carries trusted turn runtime environment values" do
    envelope =
      TurnEnvelope.turn_start(turn_ref(), actor_event(), [], %{
        workspace_id: 10_000,
        model_ref: model_ref(),
        request_context: %{},
        runtime_env: %{"ANKOLE_RUNTIME_CURRENT_ACTOR_SENDER_PRINCIPAL" => "human-alice"}
      })

    assert %FabricProto.Envelope{body: {:turn_start, turn_start}} = envelope
    assert turn_start.workspace_id == 10_000

    assert turn_start.runtime_env == %{
             "ANKOLE_RUNTIME_CURRENT_ACTOR_SENDER_PRINCIPAL" => "human-alice"
           }
  end

  defp turn_ref do
    %TurnRef{
      agent_uid: "agent-test",
      session_id: "session-test",
      activation_uid: "activation-test",
      actor_epoch: 1,
      actor_event_id: "019f7057-5fd2-76d0-a553-c6c84da72b43",
      revision: 0
    }
  end

  defp actor_event do
    %ActorEvent{
      id: "019f7057-5fd2-76d0-a553-c6c84da72b43",
      queue_sequence: 1,
      type: "im.message.addressed",
      source_event_id: "source-test",
      payload: %{}
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
