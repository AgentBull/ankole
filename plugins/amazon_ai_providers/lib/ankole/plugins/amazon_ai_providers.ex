defmodule Ankole.Plugins.AmazonAIProviders do
  @moduledoc """
  Amazon Web Services AI providers: Polly speech and Textract OCR.
  """

  @behaviour Ankole.Plugins.Plugin

  alias Ankole.Plugins.AmazonAIProviders.Providers.Amazon

  @impl true
  def plugin_id, do: "amazon-ai-providers"

  @impl true
  def display_name do
    %{"default" => "Amazon AI Providers", "zh-Hans-CN" => "Amazon AI Provider"}
  end

  @impl true
  def description do
    %{
      "default" => "Adds Amazon Polly speech and Amazon Textract OCR to AIGateway.",
      "zh-Hans-CN" => "为 AIGateway 提供 Amazon Polly 语音合成和 Amazon Textract OCR。"
    }
  end

  @impl true
  def adapter_declarations do
    [
      %{
        contract_id: "ai_gateway.provider",
        id: "amazon",
        plugin_id: plugin_id(),
        display_name: Amazon.provider_definition().label,
        module: Amazon
      }
    ]
  end

  @impl true
  def children, do: []
end
