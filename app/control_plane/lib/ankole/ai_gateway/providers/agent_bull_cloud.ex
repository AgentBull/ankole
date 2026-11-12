defmodule Ankole.AIGateway.Providers.AgentBullCloud do
  @moduledoc """
  AgentBull Cloud provider supporting multi-modal endpoints (Responses over SSE and
  WebSocket, Chat Completions, Embeddings, Rerank, Image Generation, Dual Model Catalogs)
  and meta-search (`web_search`), with dual credential support for FOSS static `ank_cloud_*`
  API keys and SaaS Pod short-lived `agb_rt_*` Hosted Caller Tokens.
  """

  use Ankole.AIGateway.ProviderDSL

  alias Ankole.AIGateway.{OpenAIRequestOptions, ReasoningEffort, UniversalAIRequest}

  @default_base_url "https://cloudapis.agentbull.com/v1"
  @timeout_ms 120_000
  @image_timeout_ms 300_000

  @doc "Signs short-lived hosted caller token claims when a hosted token provider is registered."
  @callback sign(claims :: map(), opts :: keyword()) :: {:ok, String.t()} | {:error, term()}

  provider :agentbull_cloud do
    label(%{"default" => "AgentBull Cloud", "zh-Hans-CN" => "AgentBull Cloud"})
    base_url(@default_base_url)

    setting(:api_key, encrypted: true, required: true, scope: :credential)

    setting(:endpoint_kind,
      type: :select,
      default: "responses",
      options: ~w(responses chat_completions),
      advanced: true
    )

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
      options: ReasoningEffort.Levels.values(),
      scope: :request,
      capabilities: [:language_model]
    )

    setting(:reasoningSummary,
      type: :select,
      options: OpenAIRequestOptions.reasoning_summary_values(),
      scope: :request,
      advanced: true,
      capabilities: [:language_model]
    )

    setting(:promptCacheKey, scope: :request, advanced: true, capabilities: [:language_model])

    setting(:promptCacheRetention,
      type: :select,
      options: OpenAIRequestOptions.prompt_cache_retention_values(),
      scope: :request,
      advanced: true,
      capabilities: [:language_model]
    )

    setting(:serviceTier,
      options: OpenAIRequestOptions.service_tier_values(),
      scope: :request,
      advanced: true,
      capabilities: [:language_model]
    )

    setting(:textVerbosity,
      type: :select,
      options: OpenAIRequestOptions.text_verbosity_values(),
      scope: :request,
      capabilities: [:language_model]
    )

    setting(:truncation,
      type: :select,
      options: OpenAIRequestOptions.truncation_values(),
      scope: :request,
      advanced: true,
      capabilities: [:language_model]
    )

    setting(:contextManagement,
      type: :map,
      scope: :request,
      advanced: true,
      capabilities: [:language_model]
    )

    setting(:provider, type: :map, scope: :request, advanced: true)

    setting(:sources, scope: :request, capabilities: [:web_search])
    setting(:timeRange, scope: :request, capabilities: [:web_search])
    setting(:skip_cache, scope: :request, capabilities: [:web_search])

    language_model do
      api_resolver(:openai_responses)
      prepare(:prepare_language_model)
      supports_parallel_tool_calls()
      supports_native_image_generation()
    end

    embedding_model do
      api_resolver(:openrouter_embeddings)
      prepare(:prepare_embedding_model)
    end

    rerank_model do
      api_resolver(:openrouter_rerank)
      prepare(:prepare_rerank_model)
    end

    image_generate do
      api_resolver(:openrouter_images)
      timeout_ms(@image_timeout_ms)
      prepare(:prepare_image_generate)
    end

    web_search do
      api_resolver(:agentbull_web_search)
      prepare(:prepare_web_search)
      timeout_ms(@timeout_ms)
    end
  end

  @doc "Builds an AgentBull Cloud language-model request over Responses (SSE/WS) or Chat Completions.\n\n## Errors\n\nReturns a `%UniversalAIRequest{}` or the credential error from `resolve_auth_token/1`."
  @spec prepare_language_model(map()) :: UniversalAIRequest.t() | {:error, term()}
  def prepare_language_model(ctx) when is_map(ctx) do
    with {:ok, token} <- resolve_auth_token(ctx) do
      case endpoint_kind(ctx) do
        "chat_completions" ->
          ctx
          |> UniversalAIRequest.new("chat/completions", :openai_chat_completions)
          |> apply_common_headers_and_auth(ctx, token)
          |> ReasoningEffort.put_provider_options(ctx, target: :reasoning_effort)
          |> OpenAIRequestOptions.put_provider_options(:chat_completions, ctx.request)
          |> put_anthropic_cache_control(ctx)

        _responses ->
          base =
            if websocket_mode?(ctx),
              do: websocket_transport(ctx, :openai_responses),
              else: UniversalAIRequest.new(ctx, "responses", :openai_responses)

          base
          |> apply_common_headers_and_auth(ctx, token)
          |> ReasoningEffort.put_provider_options(ctx, target: :reasoning)
          |> OpenAIRequestOptions.put_provider_options(:responses)
      end
    end
  end

  @doc "Constructs a WebSocket transport request builder for the Responses endpoint.\n\n## Errors\n\nDoes not return error tuples."
  @spec websocket_transport(map(), atom()) :: UniversalAIRequest.t()
  def websocket_transport(ctx, resolver \\ :openai_responses)
      when is_map(ctx) and is_atom(resolver) do
    UniversalAIRequest.new(ctx, "responses", resolver,
      method: "GET",
      upstream: :websocket_text
    )
  end

  @doc "Builds an AgentBull Cloud embeddings request.\n\n## Errors\n\nReturns a `%UniversalAIRequest{}` or the credential error from `resolve_auth_token/1`."
  @spec prepare_embedding_model(map()) :: UniversalAIRequest.t() | {:error, term()}
  def prepare_embedding_model(ctx) when is_map(ctx) do
    with {:ok, token} <- resolve_auth_token(ctx) do
      ctx
      |> UniversalAIRequest.new("embeddings", :openrouter_embeddings)
      |> apply_common_headers_and_auth(ctx, token)
    end
  end

  @doc "Builds an AgentBull Cloud rerank request.\n\n## Errors\n\nReturns a `%UniversalAIRequest{}` or the credential error from `resolve_auth_token/1`."
  @spec prepare_rerank_model(map()) :: UniversalAIRequest.t() | {:error, term()}
  def prepare_rerank_model(ctx) when is_map(ctx) do
    with {:ok, token} <- resolve_auth_token(ctx) do
      ctx
      |> UniversalAIRequest.new("rerank", :openrouter_rerank)
      |> apply_common_headers_and_auth(ctx, token)
    end
  end

  @doc "Builds an AgentBull Cloud `/images` request for standalone or hosted image generation.\n\n## Errors\n\nReturns a `%UniversalAIRequest{}` or the credential error from `resolve_auth_token/1`."
  @spec prepare_image_generate(map()) :: UniversalAIRequest.t() | {:error, term()}
  def prepare_image_generate(ctx) when is_map(ctx) do
    with {:ok, token} <- resolve_auth_token(ctx) do
      ctx
      |> UniversalAIRequest.new("images", :openrouter_images)
      |> apply_common_headers_and_auth(ctx, token)
    end
  end

  @doc "Builds an AgentBull Cloud `web_search` request, preserving FOSS search path and auth.\n\n## Errors\n\nReturns a `%UniversalAIRequest{}` or the credential error from `resolve_auth_token/1`."
  @spec prepare_web_search(map()) :: UniversalAIRequest.t() | {:error, term()}
  def prepare_web_search(ctx) when is_map(ctx) do
    with {:ok, token} <- resolve_auth_token(ctx) do
      ctx
      |> UniversalAIRequest.new(web_search_url(ctx), :agentbull_web_search, include_model: false)
      |> UniversalAIRequest.bearer_auth(token)
    end
  end

  # Web search lives on the host root, outside the API root that `base_url`
  # carries for model, embedding, rerank, image, and catalog endpoints.
  defp web_search_url(ctx) do
    uri =
      ctx
      |> UniversalAIRequest.setting(:base_url)
      |> then(&(&1 || @default_base_url))
      |> URI.parse()

    root_path =
      (uri.path || "")
      |> String.trim_trailing("/")
      |> String.replace_suffix("/v1", "")

    URI.to_string(%URI{
      scheme: uri.scheme,
      host: uri.host,
      port: uri.port,
      path: root_path <> "/web-search/v1/search"
    })
  end

  @doc """
  Resolves the upstream credential.

  A request that carries a hosted caller token, or the Pod identity needed to
  mint one, owns its credential path. An explicit static `api_key` is used only
  when no hosted credential material is present, and a hosted-path failure is
  returned instead of falling back to that key.

  ## Errors

  Returns `{:error, :missing_credentials}` when neither credential source is
  present, `{:error, :hosted_token_unavailable}` when the hosted path cannot
  produce a token, and `{:error, :missing_policy}` when the Pod identity is
  present but the token claims are incomplete.
  """
  @spec resolve_auth_token(map()) :: {:ok, String.t()} | {:error, term()}
  def resolve_auth_token(ctx) when is_map(ctx) do
    cond do
      hosted_caller_token_requested?(ctx) -> resolve_hosted_caller_token(ctx)
      key = extract_static_api_key(ctx) -> {:ok, key}
      true -> {:error, :missing_credentials}
    end
  end

  @impl true
  @doc "Returns the OpenRouter-compatible model metadata catalog source for `:agentbull_cloud`.\n\n## Errors\n\nReturns `{:ok, {:openrouter, map()}}` or the credential error from `resolve_auth_token/1`."
  @spec models_metadata_source(map()) :: {:ok, {:openrouter, map()}} | {:error, term()}
  def models_metadata_source(ctx) when is_map(ctx) do
    with {:ok, token} <- resolve_auth_token(ctx) do
      path = "models?output_modalities=all"
      headers = ctx |> UniversalAIRequest.raw_headers() |> UniversalAIRequest.bearer_auth(token)

      {:ok,
       {:openrouter,
        %{ctx: ctx, path: path, headers: headers, cache_key: scoped_cache_key(ctx, token, path)}}}
    end
  end

  @doc "Returns the definitive image model metadata catalog source for `:agentbull_cloud`.\n\n## Errors\n\nReturns `{:ok, map()}` or the credential error from `resolve_auth_token/1`."
  @spec image_models_metadata_source(map()) :: {:ok, map()} | {:error, term()}
  def image_models_metadata_source(ctx) when is_map(ctx) do
    with {:ok, token} <- resolve_auth_token(ctx) do
      models_path = "images/models"
      headers = ctx |> UniversalAIRequest.raw_headers() |> UniversalAIRequest.bearer_auth(token)

      {:ok,
       %{
         ctx: ctx,
         models_path: models_path,
         headers: headers,
         cache_key: scoped_cache_key(ctx, token, models_path)
       }}
    end
  end

  @doc "Builds a fallback catalog helper context for `:agentbull_cloud` in SaaS Pod mode.\n\n## Errors\n\nDoes not return error tuples."
  @spec build_catalog_context(map(), keyword()) :: map()
  def build_catalog_context(runtime, opts \\ []) when is_map(runtime) and is_list(opts) do
    provider = field(runtime, :provider, %{})
    conn_opts = if is_map(provider), do: field(provider, :connection_options, %{}), else: %{}
    merged_conn = Map.merge(field(runtime, :connection_options, %{}) || %{}, conn_opts || %{})
    base_url = field(merged_conn, :base_url, @default_base_url)

    %{
      provider_id: field(runtime, :provider_id, "agentbull_cloud"),
      provider_kind: "agentbull_cloud",
      capability: Keyword.get(opts, :capability, "image_generate"),
      provider: provider,
      runtime: runtime,
      connection: Map.put(merged_conn, "base_url", base_url),
      settings: %{base_url: base_url, api_key: field(merged_conn, :api_key)},
      pod: field(runtime, :pod, %{}),
      auth: field(runtime, :auth, %{}),
      session: field(runtime, :session, %{}),
      request_context: field(runtime, :request_context, %{}),
      options: Map.new(opts),
      timeout_ms: Keyword.get(opts, :timeout_ms, 15_000),
      http_client: Keyword.get(opts, :http_client)
    }
  end

  defp apply_common_headers_and_auth(request, ctx, token) do
    request
    |> UniversalAIRequest.put_client_identity_headers(ctx)
    |> UniversalAIRequest.bearer_auth(token)
  end

  defp put_anthropic_cache_control({:error, _reason} = error, _ctx), do: error

  defp put_anthropic_cache_control(%UniversalAIRequest{} = request, ctx) do
    provider_options = request.provider_options || %{}

    if anthropic_model?(Map.get(ctx, :model)) and
         not Map.has_key?(provider_options, "cache_control") do
      UniversalAIRequest.put_provider_options(
        request,
        Map.put(provider_options, "cache_control", %{"type" => "ephemeral"})
      )
    else
      request
    end
  end

  defp anthropic_model?(model) when is_binary(model) do
    model
    |> String.trim_leading("~")
    |> String.starts_with?("anthropic/")
  end

  defp anthropic_model?(_model), do: false

  defp endpoint_kind(ctx) do
    to_string(
      UniversalAIRequest.setting(ctx, :endpoint_kind) ||
        nested_field(ctx, :endpoint_kind) || "responses"
    )
  end

  defp upstream_transport(ctx) do
    to_string(
      UniversalAIRequest.setting(ctx, :upstream_transport) ||
        nested_field(ctx, :upstream_transport) || "sse"
    )
  end

  defp websocket_mode?(ctx) do
    stream? =
      if is_nil(field(ctx, :stream?)), do: field(ctx, :stream, true), else: field(ctx, :stream?)

    stream? != false and upstream_transport(ctx) == "websocket"
  end

  defp extract_static_api_key(ctx) do
    provider = field(ctx, :provider, %{})
    connection = field(ctx, :connection, %{})

    [
      UniversalAIRequest.setting(ctx, :api_key),
      field(ctx, :api_key),
      if(is_map(provider), do: field(provider, :api_key)),
      if(is_map(connection), do: field(connection, :api_key))
    ]
    |> Enum.find_value(fn
      key when is_binary(key) -> if(String.trim(key) != "", do: String.trim(key))
      _ -> nil
    end)
  end

  defp hosted_caller_token_requested?(ctx) do
    non_empty_str?(trusted_field(ctx, :hosted_token)) or pod_identity_present?(ctx)
  end

  defp pod_identity_present?(ctx) do
    {scope, principal} = extract_pod_identity(ctx)
    non_empty_str?(scope) and non_empty_str?(principal)
  end

  defp resolve_hosted_caller_token(ctx) do
    case trusted_field(ctx, :hosted_token) do
      token when is_binary(token) ->
        if non_empty_str?(token),
          do: {:ok, String.trim(token)},
          else: mint_hosted_token_from_scope(ctx)

      _none ->
        mint_hosted_token_from_scope(ctx)
    end
  end

  defp mint_hosted_token_from_scope(ctx) do
    with {scope, principal} <- extract_pod_identity(ctx),
         true <- non_empty_str?(scope) and non_empty_str?(principal),
         {:ok, claims} <- build_hosted_token_claims(ctx, scope, principal) do
      sign_with_registered_provider(ctx, claims)
    else
      {:error, _} = err -> err
      _ -> {:error, :hosted_token_unavailable}
    end
  end

  defp sign_with_registered_provider(ctx, claims) do
    case hosted_token_provider(ctx) do
      mod when is_atom(mod) and not is_nil(mod) ->
        if Code.ensure_loaded?(mod) and function_exported?(mod, :sign, 2) do
          case mod.sign(claims, build_token_opts(ctx)) do
            {:ok, token} when is_binary(token) ->
              if non_empty_str?(token),
                do: {:ok, String.trim(token)},
                else: {:error, :hosted_token_unavailable}

            _rejected ->
              {:error, :hosted_token_unavailable}
          end
        else
          {:error, :hosted_token_unavailable}
        end

      nil ->
        {:error, :hosted_token_unavailable}
    end
  end

  defp hosted_token_provider(ctx) do
    trusted_field(ctx, :hosted_token_provider) ||
      Application.get_env(:ankole, :hosted_token_provider)
  end

  defp extract_pod_identity(ctx) do
    {trusted_field(ctx, :isolation_scope) || trusted_field(ctx, :tenant_id),
     trusted_field(ctx, :principal_uid) || trusted_field(ctx, :subject_uid)}
  end

  defp build_hosted_token_claims(ctx, scope, principal) do
    allowed_models = trusted_field(ctx, :allowed_models)
    budget_ceiling = trusted_field(ctx, :budget_ceiling)

    if valid_allowed_models?(allowed_models) and is_integer(budget_ceiling) and budget_ceiling > 0 do
      {:ok,
       %{
         tenant_id: scope,
         isolation_scope: scope,
         principal_uid: principal,
         agent_uid: trusted_field(ctx, :agent_uid) || "agent_pod_default",
         turn_id: trusted_field(ctx, :turn_id) || "turn_#{System.unique_integer([:positive])}",
         allowed_models: allowed_models,
         budget_ceiling: budget_ceiling,
         policy_version: trusted_field(ctx, :policy_version) || 1
       }}
    else
      {:error, :missing_policy}
    end
  end

  defp valid_allowed_models?([_ | _] = list), do: Enum.all?(list, &non_empty_str?/1)
  defp valid_allowed_models?(_other), do: false

  defp non_empty_str?(val), do: is_binary(val) and String.trim(val) != ""

  defp build_token_opts(ctx) do
    []
    |> maybe_put_opt(:ttl_seconds, trusted_field(ctx, :ttl_seconds))
    |> maybe_put_opt(:now, trusted_field(ctx, :now))
    |> maybe_put_opt(:secret_key_base, trusted_field(ctx, :secret_key_base))
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, val), do: Keyword.put(opts, key, val)

  defp scoped_cache_key(ctx, token, base_key) do
    {scope, principal} = extract_pod_identity(ctx)
    digest = authorization_digest(ctx, token)
    origin = UniversalAIRequest.setting(ctx, :base_url) || @default_base_url
    key = "#{base_key}|origin=#{origin}"

    cond do
      non_empty_str?(scope) and non_empty_str?(digest) ->
        "#{key}|scope=#{scope}|principal=#{principal || "anonymous"}|tok=#{digest}"

      non_empty_str?(scope) ->
        "#{key}|scope=#{scope}|principal=#{principal || "anonymous"}"

      non_empty_str?(digest) ->
        "#{key}|tok=#{digest}"

      true ->
        key
    end
  end

  # Minted tokens carry a fresh turn id, so hashing the token would make every
  # catalog lookup a cache miss. Key on the claims that change catalog contents
  # instead, and fall back to the token only when no policy is present.
  defp authorization_digest(ctx, token) do
    case {trusted_field(ctx, :allowed_models), trusted_field(ctx, :policy_version)} do
      {nil, nil} ->
        token_digest(token)

      claims ->
        :crypto.hash(:sha256, :erlang.term_to_binary(claims))
        |> Base.url_encode64(padding: false)
    end
  end

  defp token_digest(token) when is_binary(token) and token != "" do
    :crypto.hash(:sha256, token) |> Base.url_encode64(padding: false)
  end

  defp token_digest(_other), do: nil

  defp trusted_field(ctx, key) when is_map(ctx) and is_atom(key) do
    [
      field(ctx, :auth, %{}),
      field(ctx, :pod, %{}),
      field(ctx, :session, %{})
    ]
    |> Enum.find_value(fn
      map when is_map(map) -> field(map, key)
      _ -> nil
    end)
  end

  defp nested_field(ctx, key) when is_map(ctx) and is_atom(key) do
    provider = field(ctx, :provider, %{})
    provider_cfg = if is_map(provider), do: field(provider, :config, %{}), else: %{}

    [
      ctx,
      field(ctx, :settings, %{}),
      field(ctx, :options, %{}),
      field(ctx, :metadata, %{}),
      field(ctx, :request_context, %{}),
      field(ctx, :connection, %{}),
      field(ctx, :runtime, %{}),
      provider,
      provider_cfg
    ]
    |> Enum.find_value(fn
      map when is_map(map) -> field(map, key)
      _ -> nil
    end)
  end

  defp field(map, key, default \\ nil) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, val} when not is_nil(val) -> val
      _ -> Map.get(map, Atom.to_string(key), default)
    end
  end
end
