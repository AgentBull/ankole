defmodule Ankole.AIGateway.CompactionUpstreamRealLLMTest do
  @moduledoc """
  Verifies Provider-native compaction against a real Codex-compatible upstream.

  This is the only way to prove the pass-through backend: a fake upstream can
  always be made to answer with a compaction item, so it cannot show whether a
  real endpoint accepts the trigger at all.
  """

  use Ankole.AIGatewayCase, async: false

  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AIGateway.Schemas.CompactionArtifact
  alias Ankole.Repo

  @moduletag :real_llm

  @base_url "https://ai-router.yuma.host/v1"
  @model "gpt-5.6-luna"

  setup do
    case System.get_env("ANKOLE_AI_ROUTER_KEY") do
      key when is_binary(key) and key != "" -> {:ok, api_key: key}
      _missing -> {:ok, api_key: nil}
    end
  end

  test "an opted-in Agent compacts through the real upstream", %{api_key: api_key} do
    assert is_binary(api_key),
           "set ANKOLE_AI_ROUTER_KEY to run the upstream compaction verification"

    %{principal: agent} = agent_fixture()

    assert {:ok, provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "ai-router-compaction",
               provider_kind: "openai_compatible",
               base_url: @base_url,
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => api_key}]
               },
               connection_options: %{
                 "endpoint_kind" => "responses",
                 "supports_openai_tools" => true,
                 "upstream_transport" => "websocket"
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "ai-router-compaction",
               model: @model
             })

    assert {:ok, _config} =
             Ankole.AppConfigure.put_global(
               Ankole.AIGateway.CompactionPolicy.config_definition(),
               %{"upstream" => true}
             )

    on_exit(fn ->
      Ankole.AppConfigure.delete_global(Ankole.AIGateway.CompactionPolicy.config_definition())
    end)

    body = compaction_trigger_response!(agent.uid)

    assert body["object"] == "response"
    assert body["status"] == "completed"

    assert [%{"type" => "compaction", "encrypted_content" => encrypted_content}] = body["output"]
    assert is_binary(encrypted_content) and encrypted_content != ""
    refute String.starts_with?(encrypted_content, "ankole:compact:v1:")

    assert [artifact] = Repo.all(CompactionArtifact)
    assert artifact.content["version"] == 3
    assert artifact.content["source"] == "upstream"
    assert artifact.content["binding"]["provider_row_id"] == provider.id
    assert artifact.content["binding"]["model"] == @model
    refute Map.has_key?(artifact.content, "summary")

    assert Enum.filter(artifact.content["output"], &(&1["type"] == "compaction")) ==
             body["output"]
  end

  test "the same Agent keeps the local summary while the switch is off", %{api_key: api_key} do
    assert is_binary(api_key),
           "set ANKOLE_AI_ROUTER_KEY to run the upstream compaction verification"

    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "ai-router-local-compaction",
               provider_kind: "openai_compatible",
               base_url: @base_url,
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => api_key}]
               },
               connection_options: %{
                 "endpoint_kind" => "responses",
                 "supports_openai_tools" => true,
                 "upstream_transport" => "websocket"
               }
             })

    for profile <- ["primary", "light"] do
      assert {:ok, _profile} =
               ModelProfiles.put_model_profile(agent.uid, profile, %{
                 provider_id: "ai-router-local-compaction",
                 model: @model
               })
    end

    body = compaction_trigger_response!(agent.uid)

    # The switch is off, so the same upstream is never asked to compact and the
    # reply carries an AIGateway-owned handle instead of Provider state.
    assert [%{"type" => "compaction", "encrypted_content" => encrypted_content}] = body["output"]
    assert String.starts_with?(encrypted_content, "ankole:compact:v1:")
    assert [artifact] = Repo.all(CompactionArtifact)
    assert artifact.content["version"] == 2
  end

  # Driven over the WebSocket because that is the transport the Main Agent and
  # Codex use against a real upstream.
  defp compaction_trigger_response!(agent_uid) do
    request =
      Ankole.JSON.encode!(%{
        "type" => "response.create",
        "model" => "primary",
        "input" => compaction_input()
      })

    assert {:push, pushed, _state} =
             AnkoleWeb.AIGatewayResponsesSocket.handle_in({request, [opcode: :text]}, %{
               subject_uid: agent_uid,
               subject_type: "agent",
               request_context: %{"headers" => %{"originator" => "codex_cli_rs"}}
             })

    frames =
      case pushed do
        {:text, chunk} -> [Ankole.JSON.decode!(chunk)]
        chunks -> Enum.map(chunks, fn {:text, chunk} -> Ankole.JSON.decode!(chunk) end)
      end

    refute Enum.any?(frames, &(&1["type"] == "error")), inspect(frames)

    frames
    |> Enum.find(&(&1["type"] == "response.completed"))
    |> Map.fetch!("response")
  end

  defp compaction_input do
    [
      %{
        "type" => "message",
        "role" => "user",
        "content" => "We agreed to ship the report on Tuesday and to notify support first."
      },
      %{
        "type" => "message",
        "role" => "assistant",
        "content" => "Understood. Tuesday ship, support notified beforehand."
      },
      %{"type" => "compaction_trigger"}
    ]
  end
end
