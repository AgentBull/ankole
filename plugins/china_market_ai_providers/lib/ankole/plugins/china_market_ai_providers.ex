defmodule Ankole.Plugins.ChinaMarketAIProviders do
  @moduledoc """
  China-market AI Gateway providers.
  """

  @behaviour Ankole.Plugins.Plugin

  alias Ankole.Plugins.ChinaMarketAIProviders.Providers.AlibabaCN
  alias Ankole.Plugins.ChinaMarketAIProviders.Providers.VolcengineArk
  alias Ankole.Plugins.ChinaMarketAIProviders.Providers.XiaomiMiMo
  alias Ankole.Plugins.ChinaMarketAIProviders.Providers.ZaiCodingPlan

  @providers [
    {"xiaomi_mimo", XiaomiMiMo},
    {"volcengine_ark", VolcengineArk},
    {"alibaba_cn", AlibabaCN},
    {"zai_coding_plan", ZaiCodingPlan}
  ]

  @impl true
  def plugin_id, do: "china-market-ai-providers"

  @impl true
  def api_version, do: 1

  @impl true
  def display_name do
    %{
      "default" => "China Market AI Providers",
      "zh-Hans-CN" => "中国市场 AI Provider"
    }
  end

  @impl true
  def description do
    %{
      "default" => "AI Gateway provider declarations for China-market model APIs.",
      "zh-Hans-CN" => "面向中国市场模型 API 的 AI Gateway Provider 声明。"
    }
  end

  @impl true
  def adapter_declarations do
    Enum.map(@providers, fn {id, module} ->
      %{
        contract_id: "ai_gateway.provider",
        id: id,
        plugin_id: plugin_id(),
        display_name: module.provider_definition().label,
        module: module
      }
    end)
  end

  @impl true
  def children, do: []
end
