defmodule ChineseLLMProvidersExtraTest do
  use BullX.DataCase, async: false

  alias BullX.Plugins.Discovery
  alias BullX.LLM.{Catalog, PluginProviders, Provider, Writer}
  alias ChineseLLMProvidersExtra.Providers.{VolcengineArk, XiaomiMiMo}

  @plugin_id "chinese_llm_providers_extra"
  @extension_point :"bullx.llm.req_llm_provider"
  @token_plan_base_url "https://token-plan-cn.xiaomimimo.com/anthropic"

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

    {:ok, plugin} = Discovery.discover_app(:chinese_llm_providers_extra)

    %{plugin: plugin}
  end

  test "declares xiaomi_mimo and volcengine_ark provider extensions", %{plugin: plugin} do
    assert plugin.id == @plugin_id

    assert [
             %{point: @extension_point, id: "xiaomi_mimo", module: XiaomiMiMo},
             %{point: @extension_point, id: "volcengine_ark", module: VolcengineArk}
           ] = plugin.extensions
  end

  test "registers the plugin providers through the LLM provider hook", %{plugin: plugin} do
    assert {:error, _error} = ReqLLM.provider(:xiaomi_mimo)
    assert {:error, _error} = ReqLLM.provider(:volcengine_ark)

    assert :ok = PluginProviders.sync_extensions(plugin.extensions)

    assert {:ok, XiaomiMiMo} = ReqLLM.provider(:xiaomi_mimo)
    assert {:ok, VolcengineArk} = ReqLLM.provider(:volcengine_ark)
  end

  test "catalog resolves Xiaomi MiMo provider options after hook registration", %{
    plugin: plugin
  } do
    assert :ok = PluginProviders.sync_extensions(plugin.extensions)

    assert {:ok, _provider} =
             Writer.put_provider(%{
               provider_id: "mimo_cn",
               req_llm_provider: "xiaomi_mimo",
               provider_options: %{"xiaomi_mimo_billing_plan" => "token_plan"}
             })

    assert {:ok, resolved} = Catalog.resolve_model_spec("mimo_cn:mimo-v1")

    assert resolved.req_llm_provider == :xiaomi_mimo
    assert resolved.model_input == %{provider: :xiaomi_mimo, id: "mimo-v1"}
    assert resolved.opts[:provider_options] == [xiaomi_mimo_billing_plan: :token_plan]
  end

  test "Xiaomi MiMo token plan uses the token-plan endpoint" do
    assert {:ok, request} =
             XiaomiMiMo.prepare_request(
               :chat,
               %{provider: :xiaomi_mimo, id: "mimo-v1"},
               [%{role: "user", content: "hi"}],
               api_key: "test-key",
               provider_options: [xiaomi_mimo_billing_plan: :token_plan]
             )

    assert request.options[:base_url] == @token_plan_base_url
  end

  test "Volcengine Ark exposes OpenAI-compatible provider defaults" do
    assert VolcengineArk.provider_id() == :volcengine_ark
    assert VolcengineArk.default_base_url() == "https://ark.cn-beijing.volces.com/api/v3"

    assert Provider.changeset(%Provider{}, %{
             provider_id: "ark",
             req_llm_provider: "volcengine_ark"
           }).valid?
  end
end
