defmodule Ankole.Plugins.VercelWorkerProvider do
  @moduledoc "The Vercel Sandbox Worker provider."

  @behaviour Ankole.Plugins.Plugin

  @impl true
  def plugin_id, do: "vercel-worker-provider"

  @impl true
  def display_name,
    do: %{"default" => "Vercel Worker Provider", "zh-Hans-CN" => "Vercel Worker 提供方"}

  @impl true
  def description do
    %{
      "default" => "Runs Workers in Vercel Sandbox with one persistent Drive per Agent.",
      "zh-Hans-CN" => "在 Vercel Sandbox 中运行 Worker，每个 Agent 使用独立的持久 Drive。"
    }
  end

  @impl true
  def adapter_declarations do
    [
      %{
        contract_id: "agent_workers.provider_kind",
        id: "vercel",
        module: Ankole.Plugins.VercelWorkerProvider.Provider
      }
    ]
  end
end
