defmodule Ankole.AIGateway.Providers.GoogleAIStudioOpenAI do
  @moduledoc """
  Google AI Studio OpenAI-compatible provider.
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

  provider "google_ai_studio_openai" do
    label(%{
      "default" => "Google AI Studio",
      "zh-Hans-CN" => "Google AI Studio"
    })

    base_url("https://generativelanguage.googleapis.com/v1beta/openai", advanced: true)

    setting(:api_key, encrypted: true)
    setting(:headers, type: :map, advanced: true)
    setting(:query_params, type: :map, advanced: true)

    setting(:user, scope: :request, advanced: true)

    setting(:reasoningEffort,
      type: :select,
      default: ReasoningEffort.default(),
      options: ReasoningEffort.values(@reasoning_effort_map),
      scope: :request
    )

    setting(:textVerbosity, scope: :request)
    setting(:strictJSONSchema, type: :boolean, scope: :request, advanced: true)
    setting(:taskType, scope: :request, advanced: true)
    setting(:title, scope: :request, advanced: true)
    setting(:outputDimensionality, type: :integer, scope: :request, advanced: true)
    setting(:autoTruncate, type: :boolean, scope: :request, advanced: true)

    language_model do
      upstream(:sse)
      api_resolver(:openai_chat_completions)
      prepare(:prepare_language_model)
      supports_parallel_tool_calls()
    end

    embedding_model do
      upstream(:json)
      api_resolver(:google_embeddings)
      prepare(:prepare_embedding_model)
    end
  end

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
    |> ReasoningEffort.put_provider_options(ctx,
      target: :reasoning_effort,
      map: @reasoning_effort_map
    )
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
  Prepares a Google AI Studio connection check through the native Gemini model catalog endpoint.
  """
  @impl true
  def prepare_connection_check(ctx) when is_map(ctx) do
    credential = ctx.settings[:api_key] || ""

    ProviderConnectionCheck.get(
      ctx,
      "https://generativelanguage.googleapis.com/v1beta/models?key=#{URI.encode_www_form(credential)}",
      headers: []
    )
  end

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

  defp google_model_path("models/" <> _rest = model), do: model
  defp google_model_path(model), do: "models/#{model}"

  defp batch_embedding_input?(input) when is_list(input) and input != [],
    do: not token_vector?(input)

  defp batch_embedding_input?(_input), do: false

  defp token_vector?(input), do: Enum.all?(input, &is_integer/1)
end
