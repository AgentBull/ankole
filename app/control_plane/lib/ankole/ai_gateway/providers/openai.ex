defmodule Ankole.AIGateway.Providers.OpenAI do
  @moduledoc """
  First-party OpenAI provider.
  """

  use Ankole.AIGateway.ProviderDSL

  alias Ankole.AIGateway.ReasoningEffort
  alias Ankole.AIGateway.UniversalAIRequest

  provider :openai do
    label(%{"default" => "OpenAI", "zh-Hans-CN" => "OpenAI"})
    base_url("https://api.openai.com/v1")

    setting(:api_key, encrypted: true)
    setting(:endpoint_kind, default: "responses")
    setting(:upstream_transport)
    setting(:organization)
    setting(:project)
    setting(:headers, type: :map)
    setting(:query_params, type: :map)
    setting(:include_usage, type: :boolean)
    setting(:supports_structured_outputs, type: :boolean)

    setting(:reasoningEffort, scope: :request)
    setting(:reasoningSummary, scope: :request)
    setting(:promptCacheKey, scope: :request)
    setting(:promptCacheRetention, scope: :request)
    setting(:serviceTier, scope: :request)
    setting(:strictJsonSchema, scope: :request)
    setting(:textVerbosity, scope: :request)
    setting(:truncation, scope: :request)
    setting(:systemMessageMode, scope: :request)
    setting(:forceReasoning, scope: :request)
    setting(:contextManagement, scope: :request)
    setting(:allowedTools, scope: :request)

    language_model do
      upstream(:sse)
      api_resolver(:openai_responses)
      prepare(:prepare_language_model)
    end
  end

  @doc """
  Builds an OpenAI language-model request.

  Streaming Responses can use OpenAI's WebSocket mode when explicitly selected.
  Chat Completions and non-WebSocket requests stay on SSE because the Rust
  resolver already normalizes both upstream formats to downstream-ready chunks.
  """
  def prepare_language_model(%{stream?: true, settings: %{upstream_transport: "websocket"}} = ctx) do
    case endpoint_kind(ctx) do
      "responses" ->
        ctx
        |> UniversalAIRequest.new("responses", :openai_responses,
          method: "GET",
          upstream: :websocket_text
        )
        |> openai_headers()
        |> UniversalAIRequest.bearer_auth()
        |> ReasoningEffort.put_provider_options(ctx)

      _endpoint ->
        prepare_sse_language_model(ctx)
    end
  end

  def prepare_language_model(ctx), do: prepare_sse_language_model(ctx)

  @doc """
  Checks OpenAI connectivity through the native model catalog path.

  Organization and project headers are optional OpenAI routing headers, so they
  are added only when configured.
  """
  @impl true
  def check_connection(ctx) when is_map(ctx) do
    headers =
      ctx
      |> UniversalAIRequest.raw_headers()
      |> UniversalAIRequest.put_new_header("openai-organization", ctx.settings[:organization])
      |> UniversalAIRequest.put_new_header("openai-project", ctx.settings[:project])
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

  # Endpoint kind is an operator choice because some OpenAI-compatible models or
  # deployments still need Chat Completions, while OpenAI's preferred first-party
  # path is Responses.
  defp prepare_sse_language_model(ctx) do
    case endpoint_kind(ctx) do
      "chat_completions" ->
        ctx
        |> UniversalAIRequest.new("chat/completions", :openai_chat_completions)
        |> openai_headers()
        |> UniversalAIRequest.bearer_auth()
        |> ReasoningEffort.put_provider_options(ctx)

      _endpoint_kind ->
        ctx
        |> UniversalAIRequest.new("responses", :openai_responses)
        |> openai_headers()
        |> UniversalAIRequest.bearer_auth()
        |> ReasoningEffort.put_provider_options(ctx)
    end
  end

  # `put_new` keeps operator-supplied headers in control when they need to route
  # a request to a specific OpenAI organization or project.
  defp openai_headers(request) do
    request
    |> UniversalAIRequest.put_new_setting_header("openai-organization", :organization)
    |> UniversalAIRequest.put_new_setting_header("openai-project", :project)
  end

  # `compatible` is accepted as a stored option value from older OpenAI-style
  # configuration screens, but it maps to Chat Completions in the prepared
  # request contract.
  defp endpoint_kind(ctx) do
    case ctx.settings[:endpoint_kind] do
      "chat_completions" -> "chat_completions"
      "compatible" -> "chat_completions"
      _kind -> "responses"
    end
  end
end
