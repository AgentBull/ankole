defmodule Ankole.Plugins.ChinaMarketAIProviders.Providers.VolcengineArk do
  @moduledoc """
  Volcengine Ark provider backed by its OpenAI-compatible chat endpoint.
  """

  use Ankole.AIGateway.ProviderDSL

  alias Ankole.AIGateway.ReasoningEffort
  alias Ankole.AIGateway.UniversalAIRequest

  @reasoning_effort_map %{
    "low" => "low",
    "medium" => "medium",
    "high" => "high"
  }

  @doubao_metadata [
    %{
      "id" => "doubao-seed-1-6",
      "name" => "Doubao Seed 1.6",
      "aliases" => ["doubao-seed-1.6", "doubao-seed-1-6-250615"],
      "context_length" => 256_000,
      "top_provider" => %{"context_length" => 256_000, "max_completion_tokens" => 32_000},
      "supported_parameters" => ~w(
        temperature top_p max_tokens max_output_tokens response_format tools tool_choice
        reasoningEffort parallel_tool_calls promptCacheKey
      )
    },
    %{
      "id" => "doubao-seed-1-6-flash",
      "name" => "Doubao Seed 1.6 Flash",
      "aliases" => ["doubao-seed-1.6-flash", "doubao-seed-1-6-flash-250615"],
      "context_length" => 256_000,
      "top_provider" => %{"context_length" => 256_000, "max_completion_tokens" => 32_000},
      "supported_parameters" => ~w(
        temperature top_p max_tokens max_output_tokens response_format tools tool_choice
        reasoningEffort parallel_tool_calls promptCacheKey
      )
    },
    %{
      "id" => "doubao-seed-1-6-thinking",
      "name" => "Doubao Seed 1.6 Thinking",
      "aliases" => ["doubao-seed-1.6-thinking", "doubao-seed-1-6-thinking-250615"],
      "context_length" => 256_000,
      "top_provider" => %{"context_length" => 256_000, "max_completion_tokens" => 32_000},
      "supported_parameters" => ~w(
        temperature top_p max_tokens max_output_tokens response_format tools tool_choice
        reasoningEffort parallel_tool_calls promptCacheKey
      )
    },
    %{
      "id" => "doubao-seed-2-0-pro",
      "name" => "Doubao Seed 2.0 Pro",
      "aliases" => ["doubao-seed-2.0-pro", "doubao-seed-2-0-pro-260215"],
      "context_length" => 256_000,
      "top_provider" => %{"context_length" => 256_000, "max_completion_tokens" => 128_000},
      "supported_parameters" => ~w(
        temperature top_p max_tokens max_output_tokens response_format tools tool_choice
        reasoningEffort parallel_tool_calls promptCacheKey
      )
    }
  ]

  provider "volcengine_ark" do
    label(%{"default" => "Volcengine Ark", "zh-Hans-CN" => "火山引擎 Ark"})
    base_url("https://ark.cn-beijing.volces.com/api/v3", advanced: true)

    setting(:api_key, encrypted: true, scope: :credential)
    setting(:headers, type: :map, advanced: true)
    setting(:query_params, type: :map, advanced: true)

    setting(:user, scope: :request, advanced: true)
    setting(:promptCacheKey, scope: :request, advanced: true)

    setting(:reasoningEffort,
      type: :select,
      options: ReasoningEffort.Levels.values(@reasoning_effort_map),
      scope: :request
    )

    language_model do
      api_resolver(:openai_chat_completions)
      prepare(:prepare_language_model)
      supports_parallel_tool_calls()
    end
  end

  def prepare_language_model(ctx) do
    ctx
    |> UniversalAIRequest.new("chat/completions", :openai_chat_completions)
    |> UniversalAIRequest.bearer_auth()
    |> ReasoningEffort.put_provider_options(ctx,
      target: :reasoning_effort,
      map: @reasoning_effort_map
    )
    |> UniversalAIRequest.rename_provider_option("promptCacheKey", "prompt_cache_key")
    |> put_prompt_cache_key(ctx)
  end

  defp put_prompt_cache_key({:error, _reason} = error, _ctx), do: error

  defp put_prompt_cache_key(%UniversalAIRequest{} = request, ctx) do
    case Map.get(ctx.request || %{}, "prompt_cache_key") do
      key when is_binary(key) and key != "" ->
        UniversalAIRequest.put_provider_options(
          request,
          Map.put_new(request.provider_options || %{}, "prompt_cache_key", key)
        )

      _missing ->
        request
    end
  end

  @impl true
  def models_metadata_source(_ctx), do: {:ok, {:static, @doubao_metadata}}
end
