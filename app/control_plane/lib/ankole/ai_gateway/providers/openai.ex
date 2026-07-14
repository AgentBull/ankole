defmodule Ankole.AIGateway.Providers.OpenAI do
  @moduledoc """
  First-party OpenAI provider.
  """

  use Ankole.AIGateway.ProviderDSL

  alias Ankole.AIGateway.ProviderConnectionCheck
  alias Ankole.AIGateway.ReasoningEffort
  alias Ankole.AIGateway.UniversalAIRequest

  provider :openai do
    label(%{"default" => "OpenAI", "zh-Hans-CN" => "OpenAI"})
    base_url("https://api.openai.com/v1", advanced: true)

    setting(:api_key, encrypted: true)
    setting(:endpoint_kind, default: "responses", advanced: true)
    setting(:upstream_transport, advanced: true)
    setting(:organization, advanced: true)
    setting(:project, advanced: true)
    setting(:headers, type: :map, advanced: true)
    setting(:query_params, type: :map, advanced: true)

    setting(:reasoningEffort,
      type: :select,
      default: ReasoningEffort.default(),
      options: ReasoningEffort.values(),
      scope: :request
    )

    setting(:reasoningSummary, scope: :request)
    setting(:promptCacheKey, scope: :request, advanced: true)
    setting(:promptCacheRetention, scope: :request, advanced: true)
    setting(:serviceTier, scope: :request, advanced: true)
    setting(:strictJSONSchema, type: :boolean, scope: :request, advanced: true)
    setting(:textVerbosity, scope: :request)
    setting(:truncation, scope: :request, advanced: true)
    setting(:systemMessageMode, scope: :request, advanced: true)
    setting(:forceReasoning, type: :boolean, scope: :request, advanced: true)
    setting(:contextManagement, type: :map, scope: :request, advanced: true)
    setting(:allowedTools, scope: :request, advanced: true)

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
        |> ReasoningEffort.put_provider_options(ctx, target: :reasoning)

      _endpoint ->
        prepare_sse_language_model(ctx)
    end
  end

  def prepare_language_model(ctx), do: prepare_sse_language_model(ctx)

  @doc """
  Prepares an OpenAI connection check through the native model catalog path.

  Organization and project headers are optional OpenAI routing headers, so they
  are added only when configured.
  """
  @impl true
  def prepare_connection_check(ctx) when is_map(ctx) do
    headers =
      ctx
      |> UniversalAIRequest.raw_headers()
      |> UniversalAIRequest.put_new_header("openai-organization", ctx.settings[:organization])
      |> UniversalAIRequest.put_new_header("openai-project", ctx.settings[:project])
      |> UniversalAIRequest.bearer_auth(ctx.settings[:api_key])

    ProviderConnectionCheck.get(ctx, "models", headers: headers)
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
        |> ReasoningEffort.put_provider_options(ctx, target: :reasoning_effort)

      _endpoint_kind ->
        ctx
        |> UniversalAIRequest.new("responses", :openai_responses)
        |> openai_headers()
        |> UniversalAIRequest.bearer_auth()
        |> ReasoningEffort.put_provider_options(ctx, target: :reasoning)
    end
  end

  # `put_new` keeps operator-supplied headers in control when they need to route
  # a request to a specific OpenAI organization or project.
  defp openai_headers(request) do
    request
    |> UniversalAIRequest.put_new_setting_header("openai-organization", :organization)
    |> UniversalAIRequest.put_new_setting_header("openai-project", :project)
  end

  defp endpoint_kind(ctx) do
    case ctx.settings[:endpoint_kind] do
      "chat_completions" -> "chat_completions"
      _kind -> "responses"
    end
  end
end
