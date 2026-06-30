defmodule Ankole.Plugins.ChinaMarketAIProviders.Providers.VolcengineArk do
  @moduledoc """
  Volcengine Ark provider backed by its OpenAI-compatible chat endpoint.
  """

  use Ankole.AIGateway.ProviderDSL

  alias Ankole.AIGateway.UniversalAIRequest

  provider "volcengine_ark" do
    label(%{"default" => "Volcengine Ark", "zh-Hans-CN" => "火山引擎 Ark"})
    base_url("https://ark.cn-beijing.volces.com/api/v3")

    setting(:api_key, encrypted: true)
    setting(:headers, type: :map)
    setting(:query_params, type: :map)
    setting(:include_usage, type: :boolean)
    setting(:supports_structured_outputs, type: :boolean)

    setting(:user, scope: :request)
    setting(:reasoning, scope: :request)
    setting(:reasoningEffort, scope: :request)
    setting(:textVerbosity, scope: :request)
    setting(:strictJsonSchema, scope: :request)

    language_model do
      upstream(:sse)
      api_resolver(:openai_chat_completions)
      prepare(:prepare_language_model)
    end
  end

  def prepare_language_model(ctx) do
    ctx
    |> UniversalAIRequest.new("chat/completions", :openai_chat_completions)
    |> UniversalAIRequest.bearer_auth()
  end

  @impl true
  def check_connection(ctx) when is_map(ctx) do
    headers =
      ctx
      |> UniversalAIRequest.raw_headers()
      |> UniversalAIRequest.bearer_auth(ctx.settings[:api_key])

    with {:ok, %{"status" => status, "body" => body}} when status in 200..299 <-
           UniversalAIRequest.raw_get(ctx, "models", headers: headers) do
      {:ok, body}
    else
      {:ok, %{"status" => status, "body" => body}} ->
        {:error, {:provider_connection_check_failed, status, body}}

      {:error, _reason} = error ->
        error
    end
  end
end
