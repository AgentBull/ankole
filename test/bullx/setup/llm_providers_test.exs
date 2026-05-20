defmodule BullX.Setup.LLMProvidersTest do
  use BullX.DataCase, async: false

  alias BullX.LLM.PluginProviders
  alias BullX.Setup.LLMProviders

  setup do
    ReqLLM.Providers.initialize()
    PluginProviders.sync_builtin_extensions()

    on_exit(fn ->
      ReqLLM.Providers.initialize()
      PluginProviders.sync_builtin_extensions()
    end)

    :ok
  end

  test "provider catalog exposes BullX-declared providers instead of the raw req_llm registry" do
    catalog = LLMProviders.provider_catalog()
    ids = Enum.map(catalog, & &1.id)

    assert "openai" in ids
    assert "openrouter" in ids
    assert "amazon_bedrock" in ids
    assert Enum.find(catalog, &(&1.id == "openai")).label_key == "setup.llm.providers.openai"

    refute "alibaba" in ids
    refute "cerebras" in ids
    refute "groq" in ids
    refute "zai_coder" in ids
  end

  test "provider catalog maps list schemas to list input controls" do
    catalog = LLMProviders.provider_catalog()

    anthropic = Enum.find(catalog, &(&1.id == "anthropic"))

    assert Enum.find(anthropic.provider_options, &(&1.key == "stop_sequences")).input_type ==
             "string_list"

    bedrock = Enum.find(catalog, &(&1.id == "amazon_bedrock"))

    assert Enum.find(bedrock.provider_options, &(&1.key == "embedding_types")).input_type ==
             "select_list"

    assert Enum.find(bedrock.provider_options, &(&1.key == "inputs")).input_type == "json_list"
  end

  test "setup rejects raw req_llm providers that BullX did not declare" do
    assert :groq in ReqLLM.Providers.list()

    assert {:error, %{field: "req_llm_provider", details: "groq"}} =
             LLMProviders.check(%{
               "provider_id" => "groq",
               "req_llm_provider" => "groq",
               "provider_options" => %{}
             })
  end
end
