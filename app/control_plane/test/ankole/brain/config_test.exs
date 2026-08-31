defmodule Ankole.Brain.ConfigTest do
  use Ankole.AIGatewayCase

  alias Ankole.AppConfigure
  alias Ankole.Brain.Config
  alias Ankole.Principals

  setup do
    allow_cache_database_access()
    AppConfigure.Cache.clear_for_test()
    on_exit(fn -> AppConfigure.Cache.clear_for_test() end)
    :ok
  end

  test "the maintainer Agent owns Brain task profiles while Brain owns embedding and rerank" do
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

    agent_uid =
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
    assert {:ok, ^rerank} = AppConfigure.put_global_by_key("brain.rerank_model", rerank)

    assert Config.maintainer_agent_uid() == agent_uid
    assert {:ok, ^agent_uid} = Config.maintainer_subject_uid()
    assert Config.extraction_model()["model"] == "light-model"
    assert Config.dreaming_model()["model"] == "heavy-model"
    assert Config.web_fetch_model()["provider_id"] == "brain-config-web-fetch"
    assert Config.embedding_model() == embedding
    assert Config.rerank_model() == rerank

    keys = Config.definitions() |> Enum.map(& &1.key) |> MapSet.new()
    assert MapSet.member?(keys, "brain.maintainer_agent_uid")
    refute MapSet.member?(keys, "brain.extraction_model")
    refute MapSet.member?(keys, "brain.dreaming_model")
    refute MapSet.member?(keys, "brain.web_fetch_model")
  end

  test "Brain model calls require a selected existing Agent identity" do
    assert {:error, :brain_maintainer_agent_not_configured} = Config.maintainer_subject_uid()

    assert {:ok, "missing-maintainer"} =
             AppConfigure.put_global_by_key("brain.maintainer_agent_uid", "missing-maintainer")

    assert {:error, :agent_not_found} = Config.maintainer_subject_uid()
  end

  test "a disabled maintainer Agent stops Brain execution until it is replaced or enabled" do
    %{principal: maintainer} = agent_fixture()
    %{principal: replacement} = agent_fixture()

    assert {:ok, maintainer_uid} =
             AppConfigure.put_global_by_key("brain.maintainer_agent_uid", maintainer.uid)

    assert maintainer_uid == maintainer.uid
    assert {:ok, maintainer_uid} == Config.maintainer_subject_uid()

    assert {:ok, %{status: :disabled}} = Principals.disable_principal(maintainer.uid)

    assert {:error, :brain_maintainer_agent_disabled} = Config.maintainer_subject_uid()
    assert {:error, :brain_maintainer_agent_disabled} = Config.maintainer_model_profile("light")
    assert Config.extraction_model() == nil
    assert Config.dreaming_model() == nil
    assert Config.web_fetch_model() == nil

    assert {:ok, replacement_uid} =
             AppConfigure.put_global_by_key("brain.maintainer_agent_uid", replacement.uid)

    assert replacement_uid == replacement.uid
    assert {:ok, replacement_uid} == Config.maintainer_subject_uid()

    assert {:ok, maintainer_uid} =
             AppConfigure.put_global_by_key("brain.maintainer_agent_uid", maintainer.uid)

    assert {:ok, %{status: :active}} = Principals.enable_agent(maintainer.uid)
    assert {:ok, maintainer_uid} == Config.maintainer_subject_uid()
  end
end
