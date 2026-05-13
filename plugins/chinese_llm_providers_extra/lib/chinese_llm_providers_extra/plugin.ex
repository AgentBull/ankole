defmodule ChineseLLMProvidersExtra.Plugin do
  @moduledoc """
  Registers additional China-market LLM providers with BullX.

  The plugin has no runtime children. When enabled, BullX consumes these
  declarations through the `bullx_ai_agent.req_llm_provider` extension point and
  rebuilds the `req_llm` provider registry on startup.
  """

  use BullX.Plugins.Plugin

  @extension_point :"bullx_ai_agent.req_llm_provider"

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
      }
    ]
  end
end
