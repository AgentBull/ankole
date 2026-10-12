defmodule Ankole.Conversations.ModelRequestTest do
  use ExUnit.Case, async: true
  alias Ankole.Conversations.{Model, Run, Tool}
  alias Ankole.SignalsGateway.ActorEvent

  test "a scheduled round with client tools does not force JSON" do
    tool =
      Tool.new(
        %{"type" => "function", "name" => "command", "parameters" => %{"type" => "object"}},
        :worker
      )

    request = Model.request(%{run() | tools: [tool]})
    assert [%{"name" => "command"}] = request["tools"]
    refute Map.has_key?(request, "text")
    refute Map.has_key?(request, "tool_choice")
  end

  test "a scheduled round with hosted tools does not force JSON" do
    request = Model.request(%{run() | hosted_tools: [%{"type" => "brain"}]})
    assert request["tools"] == [%{"type" => "brain"}]
    refute Map.has_key?(request, "text")
  end

  test "scheduled terminal tools do not force a provider JSON format" do
    finish =
      Tool.new(hd(Ankole.Conversations.Scheduled.declarations()), Ankole.Conversations.Scheduled)

    for iteration <- [0, 1, 5] do
      request = Model.request(%{run() | tools: [finish], iteration: iteration})
      assert [%{"name" => "finish_scheduled"}] = request["tools"]
      refute Map.has_key?(request, "text")
      refute Map.has_key?(request, "response_format")
    end
  end

  test "an ordinary round without tools has no scheduled result schema" do
    refute Map.has_key?(Model.request(%{run() | kind: :main}), "text")
  end

  defp run do
    %Run{
      agent_uid: "test-agent",
      session_id: "cron:test",
      actor_event_id: "test-event",
      epoch: 1,
      event: %ActorEvent{type: "cron.fire", payload: %{}},
      kind: :scheduled,
      conversation: %{id: "test-conversation"},
      spec: %{
        model_ref: %{
          "provider_id" => "openrouter",
          "model" => "deepseek/deepseek-v4.1-flash",
          "profile" => "primary"
        },
        request_context: %{"ai_agent" => %{}}
      },
      instructions: "Complete this scheduled task.",
      input: []
    }
  end
end
