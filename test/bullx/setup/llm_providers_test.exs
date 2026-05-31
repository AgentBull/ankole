defmodule BullX.Setup.LLMProvidersTest do
  use BullX.DataCase, async: false

  alias BullX.LLM.{Catalog, PluginProviders, Provider}
  alias BullX.Setup.LLMProviders

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

  test "setup check rejects provider options that runtime resolution would reject" do
    assert {:error,
            %{
              field: "provider_options",
              message: "invalid provider options",
              provider_id: "bad_options"
            }} =
             LLMProviders.check(%{
               "provider_id" => "bad_options",
               "req_llm_provider" => "openai",
               "provider_options" => %{"not_real" => true}
             })
  end

  test "setup save surfaces stale provider catalog projection" do
    with_unregistered_catalog_cache(fn ->
      assert {:error,
              %{
                field: "provider",
                message: "saved but runtime projection is stale",
                details: details
              }} =
               LLMProviders.save_many([
                 %{
                   "provider_id" => "stale_setup_provider",
                   "req_llm_provider" => "openai",
                   "provider_options" => %{}
                 }
               ])

      assert details =~ "cache_refresh_failed"
      assert details =~ "stale_setup_provider"
      assert %Provider{} = Repo.get_by!(Provider, provider_id: "stale_setup_provider")
      assert {:error, :not_found} = Catalog.find_provider("stale_setup_provider")
    end)
  end

  defp with_unregistered_catalog_cache(fun) when is_function(fun, 0) do
    cache_pid = Process.whereis(BullX.LLM.Catalog.Cache)
    assert is_pid(cache_pid)

    Process.unregister(BullX.LLM.Catalog.Cache)

    try do
      fun.()
    after
      restore_registered_cache(
        BullX.LLM.Catalog.Cache,
        cache_pid,
        &BullX.LLM.Catalog.Cache.refresh_all/0
      )
    end
  end

  defp restore_registered_cache(name, pid, refresh_fun) do
    case {Process.alive?(pid), Process.whereis(name)} do
      {true, nil} ->
        Process.register(pid, name)
        refresh_fun.()

      _other ->
        :ok
    end
  end
end
