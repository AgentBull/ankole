defmodule BullX.LLM.CatalogTest do
  use BullX.DataCase, async: false

  alias BullX.LLM.{Catalog, ModelConfig, PluginProviders, Provider, Writer}
  alias BullX.LLM.Providers.OpenRouter

  setup do
    ReqLLM.Providers.initialize()
    PluginProviders.sync_builtin_extensions()

    cache_pid = GenServer.whereis(BullX.LLM.Catalog.Cache)
    Ecto.Adapters.SQL.Sandbox.allow(BullX.Repo, self(), cache_pid)
    BullX.LLM.Catalog.Cache.refresh_all()

    on_exit(fn ->
      ReqLLM.Providers.initialize()
      PluginProviders.sync_builtin_extensions()
      BullX.LLM.Catalog.Cache.refresh_all()
    end)

    :ok
  end

  test "put_provider encrypts API keys and resolves provider/model specs" do
    assert {:ok, provider} =
             Writer.put_provider(%{
               provider_id: "openai_proxy",
               req_llm_provider: "openai",
               base_url: "https://proxy.example.com/v1",
               api_key: "sk-test-secret",
               provider_options: %{"auth_mode" => "api_key"}
             })

    stored = Repo.get!(Provider, provider.id)

    assert stored.encrypted_api_key
    refute stored.encrypted_api_key == "sk-test-secret"

    assert {:ok, resolved} = Catalog.resolve_model_spec("openai_proxy:gpt-4.1-mini")

    assert resolved.provider_id == "openai_proxy"
    assert resolved.model_id == "gpt-4.1-mini"
    assert resolved.req_llm_provider == :openai

    assert resolved.model_input == %{
             provider: :openai,
             id: "gpt-4.1-mini",
             base_url: "https://proxy.example.com/v1"
           }

    assert resolved.opts[:api_key] == "sk-test-secret"
    assert resolved.opts[:provider_options] == [auth_mode: :api_key]
  end

  test "resolves model config through a local provider row" do
    assert {:ok, _provider} =
             Writer.put_provider(%{
               provider_id: "openai_proxy",
               req_llm_provider: "openai",
               base_url: "https://proxy.example.com/v1",
               api_key: "sk-test-secret",
               provider_options: %{"auth_mode" => "api_key"}
             })

    config = %ModelConfig{
      provider_id: "openai_proxy",
      model: "gpt-4.1-mini",
      reasoning_effort: :high,
      max_completion_tokens: 32_768
    }

    assert {:ok, resolved} = Catalog.resolve_model_config(config)

    assert resolved.provider_id == "openai_proxy"
    assert resolved.model_id == "gpt-4.1-mini"

    assert resolved.model_input == %{
             provider: :openai,
             id: "gpt-4.1-mini",
             base_url: "https://proxy.example.com/v1"
           }
  end

  test "resolution keeps colons inside the model id" do
    assert {:ok, _provider} =
             Writer.put_provider(%{
               provider_id: "bedrock_proxy",
               req_llm_provider: "openai",
               provider_options: %{}
             })

    assert {:ok, resolved} = Catalog.resolve_model_spec("bedrock_proxy:model:with:colon")

    assert resolved.provider_id == "bedrock_proxy"
    assert resolved.model_id == "model:with:colon"
  end

  test "rejects OpenRouter reasoning options on provider write" do
    assert {:ok, OpenRouter} = ReqLLM.provider(:openrouter)

    assert {:error,
            {:invalid_provider_options, "openrouter_default",
             {:unknown_key, "openrouter_reasoning_effort"}}} =
             Writer.put_provider(%{
               provider_id: "openrouter_default",
               req_llm_provider: "openrouter",
               provider_options: %{"openrouter_reasoning_effort" => "high"}
             })
  end

  test "unknown req_llm providers are rejected on write" do
    assert {:error, {:unknown_req_llm_provider, "missing_provider"}} =
             Writer.put_provider(%{
               provider_id: "missing",
               req_llm_provider: "missing_provider",
               provider_options: %{}
             })
  end

  test "req_llm providers not declared by BullX are rejected on write" do
    assert :groq in ReqLLM.Providers.list()

    assert {:error, {:unknown_req_llm_provider, "groq"}} =
             Writer.put_provider(%{
               provider_id: "groq",
               req_llm_provider: "groq",
               provider_options: %{}
             })
  end

  test "invalid provider options fail during write" do
    assert {:error, {:invalid_provider_options, "bad_options", {:unknown_key, "not_real"}}} =
             Writer.put_provider(%{
               provider_id: "bad_options",
               req_llm_provider: "openai",
               provider_options: %{"not_real" => true}
             })
  end

  test "updating without api_key preserves the encrypted API key" do
    assert {:ok, provider} =
             Writer.put_provider(%{
               provider_id: "preserve_key",
               req_llm_provider: "openai",
               api_key: "sk-original",
               provider_options: %{}
             })

    original = Repo.get!(Provider, provider.id).encrypted_api_key

    assert {:ok, updated} =
             Writer.update_provider("preserve_key", %{
               base_url: "https://proxy.example.com/v1"
             })

    assert Repo.get!(Provider, updated.id).encrypted_api_key == original

    assert {:ok, resolved} = Catalog.resolve_provider("preserve_key")
    assert resolved.opts[:api_key] == "sk-original"
  end

  test "put_provider reports persisted-but-stale when post-commit cache refresh fails" do
    with_unregistered_catalog_cache(fn ->
      assert {:ok, provider,
              {:persisted_but_stale, {:cache_refresh_failed, "stale_insert", :cache_not_running}}} =
               Writer.put_provider(%{
                 provider_id: "stale_insert",
                 req_llm_provider: "openai",
                 api_key: "sk-stale",
                 provider_options: %{}
               })

      assert Repo.get!(Provider, provider.id).provider_id == "stale_insert"
      assert {:error, :not_found} = Catalog.find_provider("stale_insert")
    end)
  end

  test "update_provider reports persisted-but-stale when post-commit cache refresh fails" do
    assert {:ok, provider} =
             Writer.put_provider(%{
               provider_id: "stale_update",
               req_llm_provider: "openai",
               provider_options: %{}
             })

    with_unregistered_catalog_cache(fn ->
      assert {:ok, updated,
              {:persisted_but_stale, {:cache_refresh_failed, "stale_update", :cache_not_running}}} =
               Writer.update_provider("stale_update", %{
                 base_url: "https://proxy.example.com/v1"
               })

      assert Repo.get!(Provider, updated.id).base_url == "https://proxy.example.com/v1"
      assert {:ok, cached} = Catalog.find_provider("stale_update")
      assert cached.id == provider.id
      assert cached.base_url == nil
    end)
  end

  test "deleting a provider refreshes the cache-backed catalog" do
    assert {:ok, _provider} =
             Writer.put_provider(%{
               provider_id: "delete_me",
               req_llm_provider: "openai",
               provider_options: %{}
             })

    assert {:ok, _provider} = Catalog.find_provider("delete_me")

    assert :ok = Writer.delete_provider("delete_me")

    assert {:error, :not_found} = Catalog.find_provider("delete_me")
    refute Enum.any?(Catalog.list_providers(), &(&1.provider_id == "delete_me"))
  end

  test "delete_provider reports persisted-but-stale when post-commit cache refresh fails" do
    assert {:ok, provider} =
             Writer.put_provider(%{
               provider_id: "stale_delete",
               req_llm_provider: "openai",
               provider_options: %{}
             })

    with_unregistered_catalog_cache(fn ->
      assert {:ok,
              {:persisted_but_stale, {:cache_refresh_failed, "stale_delete", :cache_not_running}}} =
               Writer.delete_provider("stale_delete")

      refute Repo.get(Provider, provider.id)
      assert {:ok, cached} = Catalog.find_provider("stale_delete")
      assert cached.id == provider.id
    end)
  end

  defp with_unregistered_catalog_cache(fun) when is_function(fun, 0) do
    cache_pid = Process.whereis(BullX.LLM.Catalog.Cache)
    assert is_pid(cache_pid)

    Process.unregister(BullX.LLM.Catalog.Cache)

    try do
      fun.()
    after
      restore_catalog_cache_name(cache_pid)
      BullX.LLM.Catalog.Cache.refresh_all()
    end
  end

  defp restore_catalog_cache_name(cache_pid) do
    case Process.whereis(BullX.LLM.Catalog.Cache) do
      nil when is_pid(cache_pid) ->
        if Process.alive?(cache_pid) do
          Process.register(cache_pid, BullX.LLM.Catalog.Cache)
        end

      _pid ->
        :ok
    end
  end
end
