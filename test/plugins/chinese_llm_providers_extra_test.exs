defmodule ChineseLLMProvidersExtraTest do
  use BullX.DataCase, async: false

  alias BullX.Plugins.Discovery
  alias BullX.LLM.{Catalog, PluginProviders, Provider, Writer}
  alias ChineseLLMProvidersExtra.Providers.{AlibabaCN, VolcengineArk, XiaomiMiMo, ZaiCodingPlan}

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
             %{point: @extension_point, id: "volcengine_ark", module: VolcengineArk},
             %{
               point: @extension_point,
               id: "alibaba_cn",
               module: AlibabaCN,
               opts: [override: true]
             },
             %{
               point: @extension_point,
               id: "zai_coding_plan",
               module: ZaiCodingPlan,
               opts: [override: true]
             }
           ] = plugin.extensions
  end

  test "registers the plugin providers through the LLM provider hook", %{plugin: plugin} do
    assert {:error, _error} = ReqLLM.provider(:xiaomi_mimo)
    assert {:error, _error} = ReqLLM.provider(:volcengine_ark)
    assert {:ok, ReqLLM.Providers.AlibabaCN} = ReqLLM.provider(:alibaba_cn)
    assert {:ok, ReqLLM.Providers.ZaiCodingPlan} = ReqLLM.provider(:zai_coding_plan)

    assert :ok = PluginProviders.sync_extensions(plugin.extensions)

    assert {:ok, XiaomiMiMo} = ReqLLM.provider(:xiaomi_mimo)
    assert {:ok, VolcengineArk} = ReqLLM.provider(:volcengine_ark)
    assert {:ok, AlibabaCN} = ReqLLM.provider(:alibaba_cn)
    assert {:ok, ZaiCodingPlan} = ReqLLM.provider(:zai_coding_plan)
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

  test "Xiaomi MiMo exposes a local configurable provider schema" do
    schema = XiaomiMiMo.provider_schema().schema

    assert Keyword.fetch!(schema, :xiaomi_mimo_billing_plan)[:type] ==
             {:in, [:pay_as_you_go, :token_plan]}

    assert Keyword.fetch!(schema, :anthropic_version)[:default] == "2023-06-01"
  end

  test "Volcengine Ark exposes OpenAI-compatible provider defaults" do
    assert VolcengineArk.provider_id() == :volcengine_ark
    assert VolcengineArk.default_base_url() == "https://ark.cn-beijing.volces.com/api/v3"

    assert Provider.changeset(%Provider{}, %{
             provider_id: "ark",
             req_llm_provider: "volcengine_ark"
           }).valid?
  end

  test "Alibaba CN and ZAI Coding Plan expose copied req_llm provider defaults" do
    assert AlibabaCN.provider_id() == :alibaba_cn
    assert AlibabaCN.default_base_url() == "https://dashscope.aliyuncs.com/compatible-mode/v1"

    assert ZaiCodingPlan.provider_id() == :zai_coding_plan
    assert ZaiCodingPlan.default_base_url() == "https://api.z.ai/api/coding/paas/v4"
  end
end
