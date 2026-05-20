defmodule BullX.LLM.PluginProvidersTest do
  use ExUnit.Case, async: false

  alias BullX.Plugins.Extension
  alias BullX.LLM.PluginProviders

  alias BullX.LLM.Providers.{
    AmazonBedrock,
    Anthropic,
    Azure,
    Deepseek,
    Google,
    GoogleVertex,
    Mistral,
    OpenAI,
    OpenRouter,
    VLLM,
    XAI,
    Zai
  }

  defmodule XiaomiMimo do
    use ReqLLM.Provider,
      id: :xiaomi_mimo,
      default_base_url: "https://mimo.example.test/v1",
      default_env_key: "XIAOMI_MIMO_API_KEY"
  end

  defmodule VolcengineArk do
    use ReqLLM.Provider,
      id: :volcengine_ark,
      default_base_url: "https://ark.example.test/api/v3",
      default_env_key: "VOLCENGINE_ARK_API_KEY"
  end

  defmodule ReplacementOpenRouter do
    use ReqLLM.Provider,
      id: :openrouter,
      default_base_url: "https://openrouter.replacement.test/api/v1",
      default_env_key: "OPENROUTER_API_KEY"
  end

  setup do
    ReqLLM.Providers.initialize()
    PluginProviders.sync_builtin_extensions()

    on_exit(fn ->
      ReqLLM.Providers.initialize()
      PluginProviders.sync_builtin_extensions()
    end)

    :ok
  end

  test "registers BullX-owned providers as built-in overrides" do
    assert {:ok, AmazonBedrock} = ReqLLM.provider(:amazon_bedrock)
    assert {:ok, Anthropic} = ReqLLM.provider(:anthropic)
    assert {:ok, Azure} = ReqLLM.provider(:azure)
    assert {:ok, Deepseek} = ReqLLM.provider(:deepseek)
    assert {:ok, Google} = ReqLLM.provider(:google)
    assert {:ok, GoogleVertex} = ReqLLM.provider(:google_vertex)
    assert {:ok, Mistral} = ReqLLM.provider(:mistral)
    assert {:ok, OpenAI} = ReqLLM.provider(:openai)
    assert {:ok, OpenRouter} = ReqLLM.provider(:openrouter)
    assert {:ok, VLLM} = ReqLLM.provider(:vllm)
    assert {:ok, XAI} = ReqLLM.provider(:xai)
    assert {:ok, Zai} = ReqLLM.provider(:zai)
  end

  test "registers new enabled plugin providers" do
    extensions = [
      extension("xiaomi_mimo", XiaomiMimo),
      extension("volcengine_ark", VolcengineArk)
    ]

    assert :ok = PluginProviders.sync_extensions(extensions)

    assert {:ok, XiaomiMimo} = ReqLLM.provider(:xiaomi_mimo)
    assert {:ok, VolcengineArk} = ReqLLM.provider(:volcengine_ark)
  end

  test "rejects replacement without explicit override" do
    assert {:ok, OpenRouter} = ReqLLM.provider(:openrouter)

    assert {:error, {:req_llm_provider_already_registered, "openrouter"}} =
             PluginProviders.sync_extensions([extension("openrouter", ReplacementOpenRouter)])
  end

  test "allows deliberate replacement with override true" do
    assert {:ok, builtin} = ReqLLM.provider(:openrouter)
    assert builtin == OpenRouter
    refute builtin == ReplacementOpenRouter

    assert :ok =
             PluginProviders.sync_extensions([
               extension("openrouter", ReplacementOpenRouter, override: true)
             ])

    assert {:ok, ReplacementOpenRouter} = ReqLLM.provider(:openrouter)
  end

  defp extension(id, module, opts \\ []) do
    %Extension{
      plugin_id: "chinese-llm-providers-extra",
      point: :"bullx.llm.req_llm_provider",
      id: id,
      module: module,
      opts: opts
    }
  end
end
