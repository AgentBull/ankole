defmodule Ankole.AIGateway.Providers.GoogleAIStudioOpenAI do
  @moduledoc """
  Google AI Studio OpenAI-compatible provider.
  """

  use Ankole.AIGateway.ProviderDSL

  alias Ankole.AIGateway.ReasoningEffort
  alias Ankole.AIGateway.UniversalAIRequest

  @reasoning_effort_map %{
    "low" => "low",
    "medium" => "medium",
    "high" => "high"
  }

  provider "google_ai_studio_openai" do
    label(%{
      "default" => "Google AI Studio",
      "zh-Hans-CN" => "Google AI Studio"
    })

    base_url("https://generativelanguage.googleapis.com/v1beta/openai", advanced: true)

    setting(:api_key, encrypted: true, scope: :credential)
    setting(:headers, type: :map, advanced: true)
    setting(:query_params, type: :map, advanced: true)

    setting(:user,
      scope: :request,
      advanced: true,
      capabilities: [:language_model, :embedding_model]
    )

    setting(:reasoningEffort,
      type: :select,
      options: ReasoningEffort.Levels.values(@reasoning_effort_map),
      scope: :request,
      capabilities: [:language_model]
    )

    # Google reads these embedding fields only on embedContent requests; the
    # chat body would carry them as unknown fields.
    setting(:taskType, scope: :request, advanced: true, capabilities: [:embedding_model])
    setting(:title, scope: :request, advanced: true, capabilities: [:embedding_model])

    setting(:outputDimensionality,
      type: :integer,
      scope: :request,
      advanced: true,
      capabilities: [:embedding_model]
    )

    setting(:autoTruncate,
      type: :boolean,
      scope: :request,
      advanced: true,
      capabilities: [:embedding_model]
    )

    language_model do
      api_resolver(:openai_chat_completions)
      prepare(:prepare_language_model)
      supports_parallel_tool_calls()
    end

    embedding_model do
      api_resolver(:google_embeddings)
      prepare(:prepare_embedding_model)
    end

    decision_model do
      api_resolver(:google_decision)
      prepare(:prepare_decision_model)
    end
  end

  @decision_unsupported_options ~w(
    user reasoningEffort taskType title outputDimensionality autoTruncate
  )

  @doc "Returns the reasoning-effort target and value map of this provider's language-model requests."
  def reasoning_effort_options, do: [target: :reasoning_effort, map: @reasoning_effort_map]

  @doc """
  Builds a Google AI Studio OpenAI-compatible chat request.

  The chat endpoint speaks OpenAI-compatible Chat Completions, so the provider
  only adds Google's client/auth headers before the shared OpenAI resolver runs
  in Rust.
  """
  def prepare_language_model(ctx) do
    ctx
    |> UniversalAIRequest.new("chat/completions", :openai_chat_completions)
    |> UniversalAIRequest.put_new_header("x-goog-api-client", "ankole-ai-gateway/0.1")
    |> UniversalAIRequest.bearer_auth()
    |> ReasoningEffort.put_provider_options(ctx, reasoning_effort_options())
  end

  @doc """
  Builds a Google native embeddings request.

  Google embeddings use the official Gemini embeddings API, not the OpenAI
  compatibility path. The absolute URL makes that native endpoint explicit while
  the Rust `google_embeddings` resolver handles the different response shape.
  """
  def prepare_embedding_model(ctx) do
    with {:ok, url} <- google_embedding_url(ctx) do
      ctx
      |> UniversalAIRequest.new(url, :google_embeddings)
      |> UniversalAIRequest.put_new_header("x-goog-api-client", "ankole-ai-gateway/0.1")
      |> UniversalAIRequest.api_key_header("x-goog-api-key")
    end
  end

  @doc """
  Builds a Google native Decisions API request.

  Google Decisions lives at `/v1beta/decisions` beside the `/openai` chat
  compatibility prefix and authenticates with `x-goog-api-key`.
  """
  def prepare_decision_model(ctx) do
    with :ok <- validate_decision_options(ctx.provider_options) do
      ctx = put_in(ctx.settings[:base_url], google_decision_base_url(ctx))

      ctx
      |> UniversalAIRequest.new("decisions", :google_decision)
      |> UniversalAIRequest.put_new_header("x-goog-api-client", "ankole-ai-gateway/0.1")
      |> UniversalAIRequest.api_key_header("x-goog-api-key")
    end
  end

  defp validate_decision_options(options) when is_map(options) do
    case Enum.find(@decision_unsupported_options, &Map.has_key?(options, &1)) do
      nil -> :ok
      option -> {:error, {:unsupported_provider_option, option, "decisions"}}
    end
  end

  defp validate_decision_options(_options), do: :ok

  # The official embeddings API uses `embedContent` for one input and
  # `batchEmbedContents` for multiple text inputs. Token vectors are not treated
  # as batches because they are one already-tokenized input.
  defp google_embedding_url(ctx) do
    model = ctx.model || ""

    cond do
      String.trim(model) == "" ->
        {:error, :missing_model}

      true ->
        method =
          if batch_embedding_input?(ctx.request["input"]),
            do: "batchEmbedContents",
            else: "embedContent"

        {:ok, "#{google_native_base_url(ctx)}/#{google_model_path(model)}:#{method}"}
    end
  end

  # The provider's chat base URL points at `/openai`; native Gemini endpoints
  # live beside that prefix.
  defp google_native_base_url(ctx) do
    ctx.settings[:base_url]
    |> to_string()
    |> String.trim_trailing("/")
    |> String.replace_suffix("/openai", "")
  end

  defp google_decision_base_url(ctx) do
    ctx
    |> google_native_base_url()
    |> String.replace_suffix("/decisions", "")
  end

  defp google_model_path("models/" <> _rest = model), do: model
  defp google_model_path(model), do: "models/#{model}"

  defp batch_embedding_input?(input) when is_list(input) and input != [],
    do: not token_vector?(input)

  defp batch_embedding_input?(_input), do: false

  defp token_vector?(input), do: Enum.all?(input, &is_integer/1)
end
