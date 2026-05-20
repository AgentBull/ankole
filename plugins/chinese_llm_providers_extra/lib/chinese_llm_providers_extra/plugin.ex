defmodule ChineseLLMProvidersExtra.Plugin do
  @moduledoc """
  Registers additional China-market LLM providers with BullX.

  The plugin has no runtime children. When enabled, BullX consumes these
  declarations through the `bullx.llm.req_llm_provider` extension point and
  rebuilds the `req_llm` provider registry on startup.
  """

  use BullX.Plugins.Plugin,
    display_name: %{"en-US" => "Extra Chinese LLM providers", "zh-Hans-CN" => "中国模型 Provider 扩展"},
    description: %{
      "en-US" => "Additional ReqLLM provider declarations for China-market model APIs.",
      "zh-Hans-CN" => "为中国市场模型 API 提供额外 ReqLLM Provider 声明。"
    }

  @extension_point :"bullx.llm.req_llm_provider"

  @impl BullX.Plugins.Plugin
  def extensions do
    [
      %{
        point: @extension_point,
        id: "xiaomi_mimo",
        module: ChineseLLMProvidersExtra.Providers.XiaomiMiMo
      },
      %{
        point: @extension_point,
        id: "volcengine_ark",
        module: ChineseLLMProvidersExtra.Providers.VolcengineArk
      },
      %{
        point: @extension_point,
        id: "alibaba_cn",
        module: ChineseLLMProvidersExtra.Providers.AlibabaCN,
        opts: [override: true]
      },
      %{
        point: @extension_point,
        id: "zai_coding_plan",
        module: ChineseLLMProvidersExtra.Providers.ZaiCodingPlan,
        opts: [override: true]
      }
    ]
  end
end
