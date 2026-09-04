defmodule Ankole.AIGateway.Providers.ChatGPTSubscription do
  @moduledoc """
  ChatGPT subscription access through the Codex Responses protocol.
  """

  use Ankole.AIGateway.ProviderDSL

  alias Ankole.AIGateway.ChatGPTProtocol
  alias Ankole.AIGateway.ProviderConnectionCheck
  alias Ankole.AIGateway.ReasoningEffort
  alias Ankole.AIGateway.UniversalAIRequest

  @codex_version "0.153.2"
  provider :chatgpt_subscription do
    label(%{
      "default" => "ChatGPT Subscription",
      "zh-Hans-CN" => "ChatGPT 订阅"
    })

    base_url("https://chatgpt.com/backend-api/codex", advanced: true)

    setting(:access_token, encrypted: true, required: true, scope: :credential)
    setting(:refresh_token, encrypted: true, scope: :credential)
    setting(:id_token, encrypted: true, scope: :credential)
    setting(:account_id, encrypted: true, scope: :credential)
    setting(:plan_type, encrypted: true, scope: :credential)
    setting(:email, encrypted: true, scope: :credential)
    setting(:last_refresh, encrypted: true, scope: :credential)
    setting(:fedramp, encrypted: true, type: :boolean, scope: :credential)

    setting(:auth_type,
      encrypted: true,
      type: :select,
      options: ~w(oauth enterprise_access_token),
      scope: :credential
    )

    setting(:auth_issuer, default: "https://auth.openai.com", advanced: true)
    setting(:originator, advanced: true)
    setting(:user_agent, advanced: true)
    setting(:headers, type: :map, advanced: true)
    setting(:query_params, type: :map, advanced: true)

    setting(:reasoningEffort,
      type: :select,
      default: ReasoningEffort.default(),
      options: ReasoningEffort.values(),
      scope: :request
    )

    setting(:serviceTier, options: ~w(fast flex), scope: :request, advanced: true)

    language_model do
      upstream(:sse)
      api_resolver(:openai_responses)
      prepare(:prepare_language_model)
      supports_parallel_tool_calls()
      supports_native_image_generation()
      supports_native_web_search()
    end
  end

  @doc """
  Builds one Codex Responses request after the pool has selected and refreshed
  the credential.
  """
  def prepare_language_model(ctx) do
    with :ok <- validate_credential(ctx.settings),
         {:ok, protocol} <- ChatGPTProtocol.prepare(ctx.request, ctx.request_context),
         {:ok, provider_options} <-
           ReasoningEffort.provider_options(ctx, target: :reasoning) do
      ctx = %{ctx | request: protocol.request}
      websocket? = ctx.stream? and ctx.request_context["downstream_transport"] == "websocket"

      request =
        if websocket? do
          UniversalAIRequest.new(ctx, "responses", :openai_responses,
            method: "GET",
            upstream: :websocket_text
          )
        else
          UniversalAIRequest.new(ctx, "responses", :openai_responses)
        end

      request
      |> UniversalAIRequest.put_provider_options(normalize_provider_options(provider_options))
      |> put_protocol_headers(ctx, protocol, websocket?)
      |> UniversalAIRequest.bearer_auth(ctx.settings[:access_token])
    end
  end

  @impl true
  def models_metadata_source(ctx) when is_map(ctx) do
    {:ok, {:codex, codex_models_source(ctx)}}
  end

  @impl true
  def prepare_connection_check(ctx) when is_map(ctx) do
    source = codex_models_source(ctx)

    ProviderConnectionCheck.get(
      ctx,
      source.path,
      headers: source.headers
    )
  end

  @doc false
  def codex_version, do: @codex_version

  @doc false
  def validate_credential_options(options) when is_map(options) do
    auth_type = Map.get(options, "auth_type", "oauth")

    cond do
      not text?(Map.get(options, "account_id")) ->
        {:error, {:credential_options, {:required, "account_id"}}}

      auth_type == "oauth" and not text?(Map.get(options, "refresh_token")) ->
        {:error, {:credential_options, {:required, "refresh_token"}}}

      auth_type == "oauth" and not text?(Map.get(options, "id_token")) ->
        {:error, {:credential_options, {:required, "id_token"}}}

      true ->
        :ok
    end
  end

  defp codex_models_source(ctx) do
    path = "models?client_version=#{@codex_version}"

    headers =
      ctx
      |> UniversalAIRequest.raw_headers()
      |> UniversalAIRequest.put_header("Authorization", bearer(ctx.settings[:access_token]))
      |> maybe_put_account_header(ctx.settings)
      |> maybe_put_identity_headers(ctx.settings, %{})
      |> maybe_put_fedramp(ctx.settings)

    %{ctx: ctx, path: path, headers: headers, cache_key: {path, ctx.settings[:account_id]}}
  end

  defp put_protocol_headers(request, ctx, protocol, websocket?) do
    inbound = Map.get(ctx.request_context, "headers", %{})

    request
    # The caller's own identity goes first; every header this provider owns
    # overwrites it below.
    |> UniversalAIRequest.put_client_identity_headers(ctx)
    |> UniversalAIRequest.put_header("Content-Type", "application/json")
    |> UniversalAIRequest.put_header("Accept", accept_header(ctx.stream?))
    |> maybe_put_keep_alive(websocket?)
    |> UniversalAIRequest.put_header(
      "OpenAI-Beta",
      if(websocket?,
        do: "responses_websockets=2026-02-06",
        else: "responses=experimental"
      )
    )
    |> UniversalAIRequest.put_header("Session_id", protocol.cache_key)
    |> maybe_put_conversation_id(protocol.cache_key, websocket?)
    |> put_main_identity_headers(inbound, protocol.cache_key)
    |> maybe_put_account_header(ctx.settings)
    |> maybe_put_identity_headers(ctx.settings, inbound)
    |> maybe_put_lite_header(protocol.lite?)
    |> maybe_put_fedramp(ctx.settings)
  end

  # A main-agent request has no Codex client headers. Derive the three related
  # identifiers from the same cache key so retries do not invent new identities.
  defp put_main_identity_headers(request, inbound, cache_key) do
    request
    |> UniversalAIRequest.put_new_header(
      "X-Client-Request-Id",
      Map.get(inbound, "x-client-request-id") || cache_key
    )
    |> UniversalAIRequest.put_new_header(
      "Thread-Id",
      Map.get(inbound, "thread-id") || cache_key
    )
    |> UniversalAIRequest.put_new_header("X-Codex-Window-Id", "#{cache_key}:0")
  end

  defp maybe_put_identity_headers(headers_or_request, settings, inbound) do
    if api_key_auth?(settings) do
      headers_or_request
    else
      originator = settings[:originator] || Map.get(inbound, "originator") || "codex_cli_rs"

      user_agent =
        settings[:user_agent] || Map.get(inbound, "user-agent") || default_user_agent()

      headers_or_request
      |> UniversalAIRequest.put_header("Originator", originator)
      |> UniversalAIRequest.put_header("User-Agent", user_agent)
    end
  end

  defp maybe_put_account_header(headers_or_request, settings) do
    if api_key_auth?(settings) do
      headers_or_request
    else
      UniversalAIRequest.put_header(
        headers_or_request,
        "ChatGPT-Account-ID",
        settings[:account_id]
      )
    end
  end

  defp maybe_put_lite_header(request, true),
    do:
      UniversalAIRequest.put_header(
        request,
        "x-openai-internal-codex-responses-lite",
        "true"
      )

  defp maybe_put_lite_header(request, false), do: request

  defp maybe_put_fedramp(request, %{fedramp: true}),
    do: UniversalAIRequest.put_header(request, "X-OpenAI-Fedramp", "true")

  defp maybe_put_fedramp(request, _settings), do: request

  defp maybe_put_conversation_id(request, cache_key, true),
    do: UniversalAIRequest.put_header(request, "Conversation_id", cache_key)

  defp maybe_put_conversation_id(request, _cache_key, false), do: request

  defp maybe_put_keep_alive(request, true), do: request

  defp maybe_put_keep_alive(request, false),
    do: UniversalAIRequest.put_header(request, "Connection", "Keep-Alive")

  defp accept_header(true), do: "text/event-stream"
  defp accept_header(false), do: "application/json"

  defp normalize_provider_options(options) do
    options
    |> rename_option("serviceTier", "service_tier")
    |> rename_option("promptCacheKey", "prompt_cache_key")
  end

  defp rename_option(options, source, target) do
    case Map.pop(options, source) do
      {nil, options} -> options
      {value, options} -> Map.put(options, target, value)
    end
  end

  defp api_key_auth?(settings),
    do: settings[:auth_type] in ["enterprise_access_token", "api_key"]

  defp validate_credential(settings) do
    cond do
      not text?(settings[:access_token]) ->
        {:error, :chatgpt_access_token_required}

      not text?(settings[:account_id]) ->
        {:error, :chatgpt_account_id_required}

      true ->
        :ok
    end
  end

  defp text?(value), do: is_binary(value) and String.trim(value) != ""

  defp bearer(nil), do: nil
  defp bearer(""), do: nil
  defp bearer(value), do: "Bearer #{String.replace_prefix(value, "Bearer ", "")}"

  defp default_user_agent do
    {os_family, os_name} = :os.type()
    {major, minor, patch} = :os.version()
    architecture = :erlang.system_info(:system_architecture) |> to_string() |> architecture()
    terminal = System.get_env("TERM") || "unknown"

    "codex_cli_rs/#{@codex_version} (#{os_name(os_family, os_name)} #{major}.#{minor}.#{patch}; #{architecture}) #{terminal}"
  end

  defp os_name(:unix, :darwin), do: "Mac OS"
  defp os_name(:unix, os_name), do: os_name |> Atom.to_string() |> String.capitalize()
  defp os_name(os_family, os_name), do: "#{os_family}-#{os_name}"

  defp architecture(value) do
    cond do
      String.contains?(value, "aarch64") -> "arm64"
      String.contains?(value, "x86_64") -> "x86_64"
      true -> value
    end
  end
end
