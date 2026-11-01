defmodule Ankole.Brain.ConfigTest do
  use Ankole.AIGatewayCase

  alias Ankole.AppConfigure
  alias Ankole.Brain.Config

  test "tenant rerank settings prevent provider disablement and identify their owner", %{
    tenant: tenant
  } do
    provider_id = "tenant-rerank-provider"

    assert {:ok, _} =
             ProviderConfigs.create_provider(%{
               provider_id: provider_id,
               provider_kind: "openrouter",
               credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "sk-test"}]}
             })

    assert {:ok, _} =
             ModelProfiles.put_default_model_profile(:tenant, "rerank", %{
               provider_id: provider_id,
               model: "rerank"
             })

    assert {:error, {:provider_in_use, references}} = ProviderConfigs.delete_provider(provider_id)
    assert "tenant:#{tenant.id}:ai_gateway.model_profiles.rerank" in references

    assert {:ok, _} = ModelProfiles.put_default_model_profile(:tenant, "rerank", nil)
    assert {:ok, _} = ProviderConfigs.delete_provider(provider_id)
  end

  test "Brain uses the system Principal and Pod profiles without an Agent" do
    {:ok, _provider} =
      ProviderConfigs.create_provider(%{
        provider_id: "brain-config-provider",
        provider_kind: "openrouter",
        base_url: "https://openrouter.ai/api/v1",
        credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "sk-test"}]}
      })

    {:ok, _provider} =
      ProviderConfigs.create_provider(%{
        provider_id: "brain-config-web-fetch",
        provider_kind: "jina_reader",
        base_url: "https://r.jina.ai",
        credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "jina-test"}]}
      })

    configure_brain_maintainer_profile!("light", "brain-config-provider", "light-model")
    configure_brain_maintainer_profile!("heavy", "brain-config-provider", "heavy-model")
    configure_brain_maintainer_profile!("web_fetch", "brain-config-web-fetch", "default")

    embedding = %{
      "provider_id" => "brain-config-provider",
      "model" => "embedding-model",
      "dimensions" => 8
    }

    rerank = %{"provider_id" => "brain-config-provider", "model" => "rerank-model"}

    assert {:ok, ^embedding} = AppConfigure.put_global_by_key("brain.embedding_model", embedding)

    assert {:ok, _} =
             ModelProfiles.put_default_model_profile(:global, "rerank", rerank)

    assert {:ok, system} = Ankole.Principals.system_principal("ankole_brain")
    assert {:ok, system_uid} = Config.execution_subject_uid()
    assert system_uid == system.uid
    assert Config.extraction_model()["model"] == "light-model"
    assert Config.dreaming_model()["model"] == "heavy-model"
    assert Config.web_fetch_model()["provider_id"] == "brain-config-web-fetch"
    assert Config.embedding_model() == embedding
    assert Config.rerank_model() == Map.put(rerank, "provider_options", %{})

    keys = Config.definitions() |> Enum.map(& &1.key) |> MapSet.new()
    refute MapSet.member?(keys, "brain.maintainer_agent_uid")
    refute MapSet.member?(keys, "brain.rerank_model")
    refute MapSet.member?(keys, "brain.extraction_model")
    refute MapSet.member?(keys, "brain.dreaming_model")
    refute MapSet.member?(keys, "brain.web_fetch_model")
  end

  test "a single Pod primary serves extraction and Dreaming" do
    {:ok, _provider} =
      ProviderConfigs.create_provider(%{
        provider_id: "brain-config-primary",
        provider_kind: "openrouter",
        credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "sk-test"}]}
      })

    configure_brain_maintainer_profile!("primary", "brain-config-primary", "primary-model")

    assert Config.extraction_model()["model"] == "primary-model"
    assert Config.dreaming_model()["model"] == "primary-model"
  end

  test "unknown fields reject a known setting without replacing its value" do
    for key <- ["brain.chunking", "brain.forgetting"] do
      before = AppConfigure.get_by_key(key)

      assert {:error, {:invalid_field, "qa_unknown"}} =
               AppConfigure.put_tenant_by_key(key, %{"qa_unknown" => 1})

      assert AppConfigure.get_by_key(key) == before
    end
  end
end
