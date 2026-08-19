defmodule Ankole.AIGateway.Providers.OpenAICompatible do
  @moduledoc """
  Generic OpenAI-compatible provider.
  """

  use Ankole.AIGateway.ProviderDSL

  alias Ankole.AIGateway.OpenAIRequestOptions
  alias Ankole.AIGateway.ProviderConnectionCheck
  alias Ankole.AIGateway.Providers
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

    setting(:supports_openai_tools, type: :boolean, default: false)

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
    ctx = keep_metadata_local(ctx)

    case {Providers.responses_endpoint?(ctx), ctx.stream?, ctx.settings[:upstream_transport]} do
      {true, true, "websocket"} ->
        ctx
        |> mark_custom_tool_emulation()
        |> UniversalAIRequest.new("responses", :openai_responses,
          method: "GET",
          upstream: :websocket_text
        )
        |> UniversalAIRequest.put_client_identity_headers(ctx)
        |> UniversalAIRequest.bearer_auth()
        |> ReasoningEffort.put_provider_options(ctx, target: :reasoning)
        |> OpenAIRequestOptions.put_provider_options(:responses)

      {true, _stream?, _transport} ->
        ctx
        |> mark_custom_tool_emulation()
        |> UniversalAIRequest.new("responses", :openai_responses)
        |> UniversalAIRequest.put_client_identity_headers(ctx)
        |> UniversalAIRequest.bearer_auth()
        |> ReasoningEffort.put_provider_options(ctx, target: :reasoning)
        |> OpenAIRequestOptions.put_provider_options(:responses)

      {false, _stream?, _transport} ->
        ctx
        |> UniversalAIRequest.new("chat/completions", :openai_chat_completions)
        |> UniversalAIRequest.put_client_identity_headers(ctx)
        |> UniversalAIRequest.bearer_auth()
        |> ReasoningEffort.put_provider_options(ctx, target: :reasoning_effort)
        |> OpenAIRequestOptions.put_provider_options(:chat_completions)
    end
  end

  # Generic compatible endpoints do not consistently implement OpenAI's
  # metadata field. AIGateway retains caller metadata in its local Response.
  defp keep_metadata_local(%{request: request} = ctx) when is_map(request) do
    %{ctx | request: Map.delete(request, "metadata")}
  end

  # A connection that does not declare official OpenAI tool support gets the
  # kernel's custom-tool emulation on the Responses wire: custom tools go
  # upstream as function tools and come back in their official shape. The
  # marker never reaches the upstream body. The Chat Completions wire needs no
  # marker because its resolver always emulates.
  defp mark_custom_tool_emulation(%{request: request} = ctx) when is_map(request) do
    if ctx.settings[:supports_openai_tools] == true do
      ctx
    else
      %{ctx | request: Map.put(request, "__ankole_emulate_custom_tools", true)}
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
end
