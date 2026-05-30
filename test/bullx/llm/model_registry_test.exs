defmodule BullX.LLM.ModelRegistryTest do
  use BullX.DataCase, async: false

  alias BullX.LLM.{ModelRegistry, PluginProviders, Writer}

  setup do
    ReqLLM.Providers.initialize()
    PluginProviders.sync_builtin_extensions()

    cache_pid = GenServer.whereis(BullX.LLM.Catalog.Cache)
    Ecto.Adapters.SQL.Sandbox.allow(BullX.Repo, self(), cache_pid)
    BullX.LLM.Catalog.Cache.refresh_all()

    original_llm_env = Application.get_env(:bullx, :llm, [])

    on_exit(fn ->
      Application.put_env(:bullx, :llm, original_llm_env)
      ReqLLM.Providers.initialize()
      PluginProviders.sync_builtin_extensions()
      BullX.LLM.Catalog.Cache.refresh_all()
    end)

    :ok
  end

  test "lists OpenRouter models through dynamic provider discovery" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/api/v1/models"

      Req.Test.json(conn, %{
        "data" => [
          %{
            "id" => "openai/gpt-4.1-mini",
            "name" => "GPT-4.1 Mini",
            "context_length" => 1_048_576,
            "top_provider" => %{"max_completion_tokens" => 32_768},
            "supported_parameters" => ["tools", "reasoning"]
          }
        ]
      })
    end)

    Application.put_env(
      :bullx,
      :llm,
      Keyword.put(Application.get_env(:bullx, :llm, []), :model_discovery_req_options,
        plug: {Req.Test, __MODULE__}
      )
    )

    assert {:ok, _provider} =
             Writer.put_provider(%{
               provider_id: "openrouter_default",
               req_llm_provider: "openrouter",
               api_key: "sk-test",
               provider_options: %{}
             })

    assert {:ok, [model]} = ModelRegistry.public_models("openrouter_default")

    assert model.provider_id == "openrouter_default"
    assert model.model == "openai/gpt-4.1-mini"
    assert model.label == "GPT-4.1 Mini"
    assert model.context_window == 1_048_576
    assert model.fallback_context_window == 80_000
    assert model.max_completion_tokens == 32_768
    assert model.reasoning.efforts == ["none", "minimal", "low", "medium", "high", "xhigh"]
    assert model.source == "dynamic"
  end

  test "falls back to local metadata when dynamic discovery fails" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_status(503)
      |> Req.Test.json(%{"error" => "down"})
    end)

    Application.put_env(
      :bullx,
      :llm,
      Keyword.put(Application.get_env(:bullx, :llm, []), :model_discovery_req_options,
        plug: {Req.Test, __MODULE__}
      )
    )

    assert {:ok, _provider} =
             Writer.put_provider(%{
               provider_id: "openrouter_default",
               req_llm_provider: "openrouter",
               api_key: "sk-test",
               provider_options: %{}
             })

    assert {:ok, [_ | _] = models} = ModelRegistry.public_models("openrouter_default")
    assert Enum.all?(models, &(&1.provider_id == "openrouter_default"))
  end

  test "lists OpenAI models dynamically and enriches context from local metadata" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/v1/models"

      Req.Test.json(conn, %{
        "data" => [
          %{"id" => "gpt-4.1-mini", "object" => "model"}
        ]
      })
    end)

    put_model_discovery_plug()

    assert {:ok, _provider} =
             Writer.put_provider(%{
               provider_id: "openai_default",
               req_llm_provider: "openai",
               api_key: "sk-test",
               provider_options: %{"auth_mode" => "api_key"}
             })

    assert {:ok, [model]} = ModelRegistry.public_models("openai_default")

    assert model.model == "gpt-4.1-mini"
    assert model.context_window == 1_047_576
    assert model.max_completion_tokens == 32_768
    assert model.source == "dynamic"
  end

  test "lists Anthropic models dynamically and enriches context from local metadata" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/v1/models"

      Req.Test.json(conn, %{
        "data" => [
          %{
            "id" => "claude-sonnet-4-5-20250929",
            "display_name" => "Claude Sonnet 4.5"
          }
        ]
      })
    end)

    put_model_discovery_plug()

    assert {:ok, _provider} =
             Writer.put_provider(%{
               provider_id: "anthropic_default",
               req_llm_provider: "anthropic",
               api_key: "sk-ant-test",
               provider_options: %{}
             })

    assert {:ok, [model]} = ModelRegistry.public_models("anthropic_default")

    assert model.model == "claude-sonnet-4-5-20250929"
    assert model.label == "Claude Sonnet 4.5"
    assert model.context_window == 200_000
    assert model.max_completion_tokens == 64_000
    assert model.source == "dynamic"
  end

  test "lists Gemini models with token limits from the Google models API" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/v1beta/models"

      Req.Test.json(conn, %{
        "models" => [
          %{
            "name" => "models/gemini-2.5-flash",
            "displayName" => "Gemini 2.5 Flash",
            "inputTokenLimit" => 1_048_576,
            "outputTokenLimit" => 65_536,
            "thinking" => true
          }
        ]
      })
    end)

    put_model_discovery_plug()

    assert {:ok, _provider} =
             Writer.put_provider(%{
               provider_id: "google_default",
               req_llm_provider: "google",
               api_key: "AIza-test",
               provider_options: %{}
             })

    assert {:ok, [model]} = ModelRegistry.public_models("google_default")

    assert model.model == "gemini-2.5-flash"
    assert model.label == "Gemini 2.5 Flash"
    assert model.context_window == 1_048_576
    assert model.max_completion_tokens == 65_536
    assert model.reasoning.efforts == ["none", "minimal", "low", "medium", "high", "xhigh"]
    assert model.source == "dynamic"
  end

  test "OpenAI-compatible local providers fall back to 80k context when metadata is absent" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/v1/models"

      Req.Test.json(conn, %{
        "data" => [
          %{"id" => "local-llama", "object" => "model"}
        ]
      })
    end)

    put_model_discovery_plug()

    assert {:ok, _provider} =
             Writer.put_provider(%{
               provider_id: "local_vllm",
               req_llm_provider: "vllm",
               base_url: "http://localhost:8000/v1",
               api_key: "local",
               provider_options: %{}
             })

    assert {:ok, [model]} = ModelRegistry.public_models("local_vllm")

    assert model.model == "local-llama"
    assert is_nil(model.context_window)
    assert model.fallback_context_window == 80_000
    assert is_nil(model.max_completion_tokens)
    assert model.source == "dynamic"
  end

  test "caches dynamic discovery within the configured TTL" do
    counter = :counters.new(1, [:atomics])

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/v1/models"
      :counters.add(counter, 1, 1)

      Req.Test.json(conn, %{
        "data" => [
          %{"id" => "cached-model-#{:counters.get(counter, 1)}", "object" => "model"}
        ]
      })
    end)

    put_model_discovery_plug(cache_ttl_seconds: 60)

    assert {:ok, _provider} =
             Writer.put_provider(%{
               provider_id: "cached_openai",
               req_llm_provider: "openai",
               api_key: "sk-test",
               provider_options: %{"auth_mode" => "api_key"}
             })

    assert {:ok, [first]} = ModelRegistry.public_models("cached_openai")
    assert {:ok, [second]} = ModelRegistry.public_models("cached_openai")

    assert first.model == "cached-model-1"
    assert second.model == "cached-model-1"
    assert :counters.get(counter, 1) == 1
  end

  test "refreshes dynamic discovery after TTL expiry" do
    counter = :counters.new(1, [:atomics])

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/v1/models"
      :counters.add(counter, 1, 1)

      Req.Test.json(conn, %{
        "data" => [
          %{"id" => "expiring-model-#{:counters.get(counter, 1)}", "object" => "model"}
        ]
      })
    end)

    put_model_discovery_plug(cache_ttl_seconds: 1)

    assert {:ok, _provider} =
             Writer.put_provider(%{
               provider_id: "expiring_openai",
               req_llm_provider: "openai",
               api_key: "sk-test",
               provider_options: %{"auth_mode" => "api_key"}
             })

    assert {:ok, [first]} = ModelRegistry.public_models("expiring_openai")
    Process.sleep(1_100)
    assert {:ok, [second]} = ModelRegistry.public_models("expiring_openai")

    assert first.model == "expiring-model-1"
    assert second.model == "expiring-model-2"
    assert :counters.get(counter, 1) == 2
  end

  test "provider row updates use a fresh model discovery cache key" do
    counter = :counters.new(1, [:atomics])

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/v1/models"
      :counters.add(counter, 1, 1)

      Req.Test.json(conn, %{
        "data" => [
          %{"id" => "updated-model-#{:counters.get(counter, 1)}", "object" => "model"}
        ]
      })
    end)

    put_model_discovery_plug(cache_ttl_seconds: 60)

    assert {:ok, _provider} =
             Writer.put_provider(%{
               provider_id: "updated_openai",
               req_llm_provider: "openai",
               api_key: "sk-test",
               provider_options: %{"auth_mode" => "api_key"}
             })

    assert {:ok, [first]} = ModelRegistry.public_models("updated_openai")

    assert {:ok, _provider} =
             Writer.update_provider("updated_openai", %{
               base_url: "https://models.example.test/v1"
             })

    assert {:ok, [second]} = ModelRegistry.public_models("updated_openai")

    assert first.model == "updated-model-1"
    assert second.model == "updated-model-2"
    assert :counters.get(counter, 1) == 2
  end

  defp put_model_discovery_plug(opts \\ []) do
    llm_env =
      :bullx
      |> Application.get_env(:llm, [])
      |> Keyword.put(:model_discovery_req_options, plug: {Req.Test, __MODULE__})
      |> maybe_put_cache_ttl(Keyword.get(opts, :cache_ttl_seconds))

    Application.put_env(
      :bullx,
      :llm,
      llm_env
    )
  end

  defp maybe_put_cache_ttl(llm_env, nil), do: llm_env

  defp maybe_put_cache_ttl(llm_env, seconds) do
    Keyword.put(llm_env, :model_discovery_cache_ttl_seconds, seconds)
  end
end
