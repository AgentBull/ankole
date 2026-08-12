defmodule Ankole.AIGateway.Providers.OpenAICompatible do
  @moduledoc """
  Generic OpenAI-compatible provider.
  """

  use Ankole.AIGateway.ProviderDSL

  alias Ankole.AIGateway.OpenAIRequestOptions
  alias Ankole.AIGateway.ProviderConnectionCheck
  alias Ankole.AIGateway.ReasoningEffort
  alias Ankole.AIGateway.UniversalAIRequest

  provider :openai_compatible do
    label(%{"default" => "OpenAI Compatible", "zh-Hans-CN" => "OpenAI 兼容"})

    setting(:api_key, encrypted: true, scope: :credential)

    setting(:endpoint_kind,
      type: :select,
      default: "chat_completions",
      options: ~w(responses chat_completions)
    )

    setting(:hosted_web_search, type: :boolean, default: false)

    setting(:upstream_transport,
      type: :select,
      default: "sse",
      options: ~w(sse websocket),
      advanced: true
    )

    setting(:headers, type: :map, advanced: true)
    setting(:query_params, type: :map, advanced: true)

    setting(:user, scope: :request, advanced: true)

    setting(:reasoningEffort,
      type: :select,
      default: ReasoningEffort.default(),
      options: ReasoningEffort.values(),
      scope: :request
    )

    setting(:serviceTier, options: ~w(fast flex), scope: :request, advanced: true)
    setting(:textVerbosity, scope: :request)
    setting(:strictJSONSchema, type: :boolean, scope: :request, advanced: true)

    language_model do
      upstream(:sse)
      api_resolver(:openai_chat_completions)
      prepare(:prepare_language_model)
    end
  end

  @doc """
  Builds a generic OpenAI-compatible language-model request.

  Streaming Responses can use the same upstream WebSocket transport as OpenAI.
  Chat Completions and non-WebSocket requests use SSE. Request body conversion
  and response normalization remain in the shared native UniversalAIClient path.
  """
  def prepare_language_model(ctx) do
    endpoint = endpoint_kind(ctx)

    case {endpoint, ctx.stream?, ctx.settings[:upstream_transport]} do
      {"responses", true, "websocket"} ->
        ctx
        |> UniversalAIRequest.new("responses", :openai_responses,
          method: "GET",
          upstream: :websocket_text
        )
        |> UniversalAIRequest.bearer_auth()
        |> ReasoningEffort.put_provider_options(ctx, target: :reasoning)
        |> OpenAIRequestOptions.put_provider_options(:responses)

      {"responses", _stream?, _transport} ->
        ctx
        |> UniversalAIRequest.new("responses", :openai_responses)
        |> UniversalAIRequest.bearer_auth()
        |> ReasoningEffort.put_provider_options(ctx, target: :reasoning)
        |> OpenAIRequestOptions.put_provider_options(:responses)

      {_endpoint, _stream?, _transport} ->
        ctx
        |> UniversalAIRequest.new("chat/completions", :openai_chat_completions)
        |> UniversalAIRequest.bearer_auth()
        |> ReasoningEffort.put_provider_options(ctx, target: :reasoning_effort)
        |> OpenAIRequestOptions.put_provider_options(:chat_completions)
    end
  end

  @doc """
  Rejects hosted `web_search` on a connection that does not use the Responses
  endpoint. Hosted tools ride the Responses wire, so a Chat Completions
  connection cannot serve them.
  """
  def validate_connection_options(options) when is_map(options) do
    if Map.get(options, "hosted_web_search") == true and
         Map.get(options, "endpoint_kind") != "responses" do
      {:error, {:connection_options, {:hosted_web_search_requires_endpoint_kind, "responses"}}}
    else
      :ok
    end
  end

  @doc """
  Prepares a connection check for providers that expose an OpenAI-compatible `/models` route.
  """
  @impl true
  def prepare_connection_check(ctx) when is_map(ctx) do
    headers =
      ctx
      |> UniversalAIRequest.raw_headers()
      |> UniversalAIRequest.bearer_auth(ctx.settings[:api_key])

    ProviderConnectionCheck.get(ctx, "models", headers: headers)
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
