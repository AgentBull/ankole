defmodule Ankole.Workflow.CreationTest do
  use Ankole.DataCase, async: true

  import Ankole.PrincipalsFixtures

  alias Ankole.Repo
  alias Ankole.Workflow
  alias Ankole.Workflow.Schemas.AgentCall
  alias Ankole.Workflow.Schemas.Run

  test "create is idempotent, clamps configured limits, and inserts no calls" do
    %{principal: agent} = agent_fixture()
    attrs = valid_attrs(agent.uid)

    assert {:ok, %{run: %Run{} = run}} = Workflow.create_with_dispatch(attrs)
    run_id = run.id
    assert {:ok, %{run: %Run{id: ^run_id}}} = Workflow.create_with_dispatch(attrs)
    assert run.concurrency == 8
    assert run.max_agent_calls == 32
    assert Repo.aggregate(Run, :count) == 1
    assert Repo.aggregate(AgentCall, :count) == 0
  end

  test "create rejects values outside product bounds before configured clamping" do
    %{principal: agent} = agent_fixture()

    assert {:error, {:invalid_workflow_concurrency, %{min: 1, max: 32}}} =
             agent.uid
             |> valid_attrs()
             |> Map.put("concurrency", 33)
             |> Workflow.create_with_dispatch()

    assert {:error, {:invalid_workflow_max_agent_calls, %{min: 1, max: 1_024}}} =
             agent.uid
             |> valid_attrs()
             |> Map.put("max_agent_calls", 1_025)
             |> Workflow.create_with_dispatch()
  end

  test "create rejects oversized and non-object arguments" do
    %{principal: agent} = agent_fixture()

    assert {:error,
            %Ash.Error.Invalid{errors: [%Ash.Error.Changes.InvalidAttribute{field: :args}]}} =
             agent.uid
             |> valid_attrs()
             |> Map.put("args", %{"payload" => String.duplicate("x", 65_536)})
             |> Workflow.create_with_dispatch()

    assert {:error,
            %Ash.Error.Invalid{errors: [%Ash.Error.Changes.InvalidAttribute{field: :args}]}} =
             agent.uid
             |> valid_attrs()
             |> Map.put("args", ["not", "an", "object"])
             |> Workflow.create_with_dispatch()
  end

  test "create rejects non-string attribute keys" do
    %{principal: agent} = agent_fixture()

    assert {:error, {:invalid_workflow_attribute_key, :title}} =
             agent.uid
             |> valid_attrs()
             |> Map.put(:title, "Atom title")
             |> Workflow.create_with_dispatch()
  end

  test "create validates delegation model_profile on new runs while preserving idempotent retry after custom profile removal" do
    %{principal: agent} = agent_fixture()

    {:ok, provider} =
      Ankole.AIGateway.ProviderConfigs.create_provider(%{
        provider_id: "wf-dispatch-" <> Ecto.UUID.generate(),
        provider_kind: "openrouter",
        base_url: "https://openrouter.ai/api/v1",
        credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "sk-test"}]}
      })

    assert {:ok, _} =
             Ankole.AIGateway.ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: provider.provider_id,
               model: "openai/gpt-5"
             })

    assert {:ok, _} =
             Ankole.AIGateway.ModelProfiles.put_model_profile(agent.uid, "review", %{
               description: "Review specialist",
               provider_id: provider.provider_id,
               model: "openai/gpt-5-mini"
             })

    assert {:error, :invalid_delegation_model_profile} =
             agent.uid
             |> valid_attrs()
             |> Map.put("source_tool_call_id", "wf-invalid-slot")
             |> Map.put("model_profile", "vision_fallback")
             |> Workflow.create_with_dispatch()

    assert {:error, :model_profile_not_configured} =
             agent.uid
             |> valid_attrs()
             |> Map.put("source_tool_call_id", "wf-missing-slot")
             |> Map.put("model_profile", "missing")
             |> Workflow.create_with_dispatch()

    assert {:ok, %{run: %Run{model_profile: "heavy"}}} =
             agent.uid
             |> valid_attrs()
             |> Map.put("source_tool_call_id", "wf-heavy-tier")
             |> Map.put("model_profile", " HEAVY ")
             |> Workflow.create_with_dispatch()

    custom_attrs =
      agent.uid
      |> valid_attrs()
      |> Map.put("source_tool_call_id", "wf-custom-idempotent")
      |> Map.put("model_profile", "review")

    assert {:ok, %{run: %Run{id: custom_run_id, model_profile: "review"}}} =
             Workflow.create_with_dispatch(custom_attrs)

    assert {:ok, _} = Ankole.AIGateway.ModelProfiles.put_model_profile(agent.uid, "review", nil)

    assert {:ok, %{run: %Run{id: ^custom_run_id, model_profile: "review"}}} =
             Workflow.create_with_dispatch(custom_attrs)

    replay_result =
      Workflow.Replay.commit_replay_pending(
        custom_run_id,
        [
          %{
            namespace: nil,
            name: "agent",
            arguments: %{"prompt" => "Check", "model_profile" => "vision_fallback"}
          }
        ],
        0
      )

    assert {:ok,
            %{
              run: %Run{
                status: :failed,
                error: %{"code" => "workflow_agent_call_invalid", "summary" => summary}
              }
            }} = replay_result

    assert is_binary(summary)
  end

  defp valid_attrs(agent_uid) do
    %{
      "source_signal_id" => Ankole.WorkFixtures.service_source(agent_uid).id,
      "agent_uid" => agent_uid,
      "owner_session_id" => "session-parent",
      "reply_route" => %{"binding_name" => "bot"},
      "source_tool_call_id" => "tool-workflow-1",
      "title" => "Review the change",
      "script" => "return await agent('Review the change');",
      "args" => %{},
      "concurrency" => 32,
      "max_agent_calls" => 1_024
    }
  end
end
