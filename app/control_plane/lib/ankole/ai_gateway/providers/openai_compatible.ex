defmodule Ankole.AIGateway.Providers.OpenAICompatible do
  @moduledoc """
  Generic OpenAI-compatible provider.
  """

  use Ankole.AIGateway.ProviderDSL

  alias Ankole.AIGateway.ReasoningEffort
  alias Ankole.AIGateway.UniversalAIRequest

  provider :openai_compatible do
    label(%{"default" => "OpenAI Compatible", "zh-Hans-CN" => "OpenAI 兼容"})

    setting(:api_key, encrypted: true)
    setting(:endpoint_kind, default: "chat_completions")
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

  @doc """
  Builds a generic OpenAI-compatible language-model request.

  The provider chooses only between Responses and Chat Completions endpoints.
  Request body conversion and response normalization remain in the shared native
  UniversalAIClient path.
  """
  def prepare_language_model(ctx) do
    endpoint = endpoint_kind(ctx)

    case endpoint do
      "responses" ->
        ctx
        |> UniversalAIRequest.new("responses", :openai_responses)
        |> UniversalAIRequest.bearer_auth()
        |> ReasoningEffort.put_provider_options(ctx)

      _endpoint ->
        ctx
        |> UniversalAIRequest.new("chat/completions", :openai_chat_completions)
        |> UniversalAIRequest.bearer_auth()
        |> ReasoningEffort.put_provider_options(ctx)
    end
  end

  @doc """
  Checks connectivity for providers that expose an OpenAI-compatible `/models` route.
  """
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

  # Unknown endpoint settings fall back to Chat Completions because that is the
  # most common shape for generic OpenAI-compatible providers.
  defp endpoint_kind(ctx) do
    case ctx.settings[:endpoint_kind] do
      "responses" -> "responses"
      _kind -> "chat_completions"
    end
  end
end
