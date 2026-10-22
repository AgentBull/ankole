defmodule Ankole.Plugins.ChinaMarketAIProviders do
  @moduledoc """
  China-market model and Worker providers.
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
  def display_name do
    %{
      "default" => "China Market AI Providers",
      "zh-Hans-CN" => "中国市场 AI Provider"
    }
  end

  @impl true
  def description do
    %{
      "default" => "Adds China-market model providers and Alibaba Function Compute Workers.",
      "zh-Hans-CN" => "提供国内模型适配器和阿里云函数计算 Worker。"
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
    end) ++
      [
        %{
          contract_id: "agent_workers.provider_kind",
          id: "function_compute",
          module: Ankole.Plugins.ChinaMarketAIProviders.WorkerProviders.FunctionCompute
        }
      ]
  end

  @impl true
  def children, do: []
end
