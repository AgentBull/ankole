defmodule BullX.LLM.CatalogTest do
  use BullX.DataCase, async: false

  alias BullX.LLM.{Catalog, PluginProviders, Provider, Writer}
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

  test "resolves OpenRouter static reasoning options through the BullX provider override" do
    assert {:ok, OpenRouter} = ReqLLM.provider(:openrouter)

    assert {:ok, _provider} =
             Writer.put_provider(%{
               provider_id: "openrouter_default",
               req_llm_provider: "openrouter",
               provider_options: %{"openrouter_reasoning_effort" => "high"}
             })

    assert {:ok, resolved} =
             Catalog.resolve_model_spec("openrouter_default:openai/gpt-oss-120b")

    assert resolved.req_llm_provider == :openrouter
    assert resolved.opts[:provider_options] == [openrouter_reasoning_effort: :high]
  end

  test "unknown req_llm providers are rejected on write" do
    assert {:error, {:unknown_req_llm_provider, "missing_provider"}} =
             Writer.put_provider(%{
               provider_id: "missing",
               req_llm_provider: "missing_provider",
               provider_options: %{}
             })
  end

  test "invalid provider options fail during resolution" do
    assert {:ok, _provider} =
             Writer.put_provider(%{
               provider_id: "bad_options",
               req_llm_provider: "openai",
               provider_options: %{"not_real" => true}
             })

    assert {:error, {:invalid_provider_options, "bad_options", {:unknown_key, "not_real"}}} =
             Catalog.resolve_provider("bad_options")
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
end
