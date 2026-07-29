defmodule Ankole.Plugins.ChinaMarketAIProviders.Providers.VolcengineArk do
  @moduledoc """
  Volcengine Ark provider backed by its OpenAI-compatible chat endpoint.
  """

  use Ankole.AIGateway.ProviderDSL

  alias Ankole.AIGateway.ProviderConnectionCheck
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
        reasoningEffort
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
        reasoningEffort
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
        reasoningEffort
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
        reasoningEffort
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

    setting(:reasoningEffort,
      type: :select,
      default: ReasoningEffort.default(),
      options: ReasoningEffort.values(@reasoning_effort_map),
      scope: :request
    )

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
    |> ReasoningEffort.put_provider_options(ctx,
      target: :reasoning_effort,
      map: @reasoning_effort_map
    )
  end

  @impl true
  def models_metadata_source(_ctx), do: {:ok, {:static, @doubao_metadata}}

  @impl true
  def prepare_connection_check(ctx) when is_map(ctx) do
    headers =
      ctx
      |> UniversalAIRequest.raw_headers()
      |> UniversalAIRequest.bearer_auth(ctx.settings[:api_key])

    ProviderConnectionCheck.get(ctx, "models", headers: headers)
  end
end
