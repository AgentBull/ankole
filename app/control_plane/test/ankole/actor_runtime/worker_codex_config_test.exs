defmodule Ankole.ActorRuntime.WorkerCodexConfigTest do
  use Ankole.AIGatewayCase

  import Ecto.Query

  alias Ankole.ActorRuntime.WorkerCodexConfig
  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.AppConfig
  alias Ankole.AppConfigure.Cache
  alias Ankole.Repo

  setup do
    allow_cache_database_access()
    :ok = WorkerCodexConfig.ensure_registered()

    definition = WorkerCodexConfig.config_override_definition()
    :ok = AppConfigure.delete_global(definition)

    {:ok, definition: definition}
  end

  test "Codex config override defaults to AIGateway and resolves agent over global", %{
    definition: definition
  } do
    %{principal: agent} = agent_fixture()

    assert {:ok, %{value: nil, source: :default}} =
             WorkerCodexConfig.resolve_config_override(agent.uid)

    global_config = %{
      "mode" => "official_subscription",
      "auth_json" => %{"tokens" => %{"id_token" => "id-token"}},
      "env" => %{"OPENAI_API_KEY" => "sk-subscription"}
    }

    assert {:ok, ^global_config} = AppConfigure.put_global(definition, global_config)

    assert {:ok, %{value: ^global_config, source: :global}} =
             WorkerCodexConfig.resolve_config_override(agent.uid)

    agent_config = %{
      "mode" => "aigateway",
      "config_toml" => "model = \"coding\"\n",
      "env" => %{"ANKOLE_AIGATEWAY_API_KEY" => "sk-agent"}
    }

    assert {:ok, ^agent_config} = AppConfigure.put_for_agent(agent.uid, definition, agent_config)

    assert {:ok, %{value: ^agent_config, source: :agent}} =
             WorkerCodexConfig.resolve_config_override(agent.uid)
  end

  test "Codex config override is encrypted at rest and validates mode/env shape", %{
    definition: definition
  } do
    config = %{
      "mode" => "official_subscription",
      "auth_json" => %{"tokens" => %{"access_token" => "codex-access-token"}},
      "env" => %{"OPENAI_API_KEY" => "sk-subscription"}
    }

    assert {:ok, ^config} = AppConfigure.put_global(definition, config)

    row =
      Repo.one!(
        from row in AppConfig, where: row.scope == "global" and row.key == ^definition.key
      )

    assert get_in(row.value, ["type"]) == "cipher"
    refute inspect(row.value) =~ "codex-access-token"
    refute inspect(row.value) =~ "sk-subscription"

    assert {:error, {:unsupported_mode, "disabled"}} =
             AppConfigure.put_global(definition, %{"mode" => "disabled"})

    assert {:error, {:unsupported_env_key, "SECRET_TOKEN"}} =
             AppConfigure.put_global(definition, %{
               "mode" => "official_subscription",
               "env" => %{"SECRET_TOKEN" => "nope"}
             })
  end

  defp allow_cache_database_access do
    case GenServer.whereis(Cache) do
      nil -> :ok
      pid -> Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    end
  end
end
