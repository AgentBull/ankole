defmodule ChineseLLMProvidersExtra.Providers.XiaomiMiMo do
  @moduledoc """
  Xiaomi MiMo provider for Anthropic-compatible message endpoints.

  MiMo supports pay-as-you-go and Token Plan billing, each with its own API key
  and base URL. BullX stores the selected billing plan on the model endpoint and
  derives the Anthropic-compatible base URL from that plan.

  The pay-as-you-go endpoint is `https://api.xiaomimimo.com/anthropic/v1/messages`.
  The Token Plan endpoint is `https://token-plan-cn.xiaomimimo.com/anthropic/v1/messages`.
  req_llm's Anthropic provider appends `/v1/messages`, so this provider's
  default base URLs intentionally stop at `/anthropic`.
  """

  @pay_as_you_go_base_url "https://api.xiaomimimo.com/anthropic"
  @token_plan_base_url "https://token-plan-cn.xiaomimimo.com/anthropic"
  @billing_plans [:pay_as_you_go, :token_plan]

  use ReqLLM.Provider,
    id: :xiaomi_mimo,
    default_base_url: "https://api.xiaomimimo.com/anthropic",
    default_env_key: "XIAOMI_MIMO_API_KEY"

  @provider_schema [
    access_token: [
      type: :string,
      doc: "OAuth access token used as Authorization Bearer credential"
    ],
    auth_mode: [
      type: {:in, [:api_key, :oauth]},
      default: :api_key,
      doc: "Authentication mode: :api_key (default) or :oauth"
    ],
    oauth_file: [
      type: :string,
      doc: "Path to an oauth/auth JSON file with provider credentials"
    ],
    auth_file: [
      type: :string,
      doc: "Alias for :oauth_file"
    ],
    oauth_http_options: [
      type: {:list, :any},
      doc: "Req options for OAuth refresh HTTP requests"
    ],
    anthropic_top_k: [
      type: :pos_integer,
      doc: "Sample from the top K options for each subsequent token (1-40)"
    ],
    anthropic_version: [
      type: :string,
      default: "2023-06-01",
      doc: "Anthropic API version to use"
    ],
    stop_sequences: [
      type: {:list, :string},
      doc: "Custom sequences that will cause the model to stop generating"
    ],
    anthropic_metadata: [
      type: :map,
      doc: "Optional metadata to include with the request"
    ],
    thinking: [
      type: :map,
      doc: "Enable thinking/reasoning for supported models"
    ],
    anthropic_prompt_cache: [
      type: :boolean,
      doc: "Enable Anthropic prompt caching"
    ],
    anthropic_prompt_cache_ttl: [
      type: :string,
      doc: "TTL for cache, e.g. \"1h\""
    ],
    anthropic_cache_messages: [
      type: {:or, [:boolean, :integer]},
      doc: "Add cache breakpoint at a message position"
    ],
    anthropic_structured_output_mode: [
      type: {:in, [:auto, :json_schema, :tool_strict]},
      default: :auto,
      doc: "Strategy for structured output generation"
    ],
    output_format: [
      type: :map,
      doc: "Internal use: structured output format configuration"
    ],
    anthropic_beta: [
      type: {:list, :string},
      doc: "Internal use: beta feature flags"
    ],
    web_search: [
      type: :map,
      doc: "Enable web search tool with optional configuration"
    ],
    web_fetch: [
      type: :map,
      doc: "Enable web fetch tool with optional configuration"
    ],
    xiaomi_mimo_billing_plan: [
      type: {:in, @billing_plans},
      default: :pay_as_you_go,
      doc: "MiMo billing plan. Token Plan uses the token-plan-cn base URL."
    ]
  ]

  @impl ReqLLM.Provider
  def prepare_request(operation, model_spec, input, opts) do
    {model_spec, opts} = prepare_anthropic_delegate(model_spec, opts)

    ReqLLM.Providers.Anthropic.prepare_request(
      operation,
      model_spec,
      input,
      opts
    )
  end

  @impl ReqLLM.Provider
  def attach_stream(model, context, opts, finch_name) do
    {model, opts} = prepare_anthropic_delegate(model, opts)

    ReqLLM.Providers.Anthropic.attach_stream(
      model,
      context,
      opts,
      finch_name
    )
  end

  @impl ReqLLM.Provider
  def encode_body(request), do: ReqLLM.Providers.Anthropic.encode_body(request)

  @impl ReqLLM.Provider
  def decode_response(request_response),
    do: ReqLLM.Providers.Anthropic.decode_response(request_response)

  @impl ReqLLM.Provider
  def decode_stream_event(event, model) do
    ReqLLM.Providers.Anthropic.decode_stream_event(event, anthropic_model_spec(model))
  end

  @impl ReqLLM.Provider
  def translate_options(operation, model, opts) do
    ReqLLM.Providers.Anthropic.translate_options(operation, anthropic_model_spec(model), opts)
  end

  @impl ReqLLM.Provider
  def tool_call_id_policy(operation, model, opts) do
    ReqLLM.Providers.Anthropic.tool_call_id_policy(operation, anthropic_model_spec(model), opts)
  end

  defp prepare_anthropic_delegate(model_spec, opts) do
    {billing_plan, opts} = pop_billing_plan(opts)
    base_url = effective_base_url(opts, billing_plan)

    {model_spec |> anthropic_model_spec() |> put_model_base_url(base_url),
     Keyword.put(opts, :base_url, base_url)}
  end

  defp pop_billing_plan(opts) do
    {top_level_plan, opts} = Keyword.pop(opts, :xiaomi_mimo_billing_plan)
    {provider_options, opts} = Keyword.pop(opts, :provider_options, [])
    {nested_plan, provider_options} = pop_provider_billing_plan(provider_options)

    opts =
      case provider_options do
        [] -> opts
        empty when empty in [%{}, nil] -> opts
        provider_options -> Keyword.put(opts, :provider_options, provider_options)
      end

    {normalize_billing_plan(top_level_plan || nested_plan), opts}
  end

  defp pop_provider_billing_plan(provider_options) when is_list(provider_options) do
    Keyword.pop(provider_options, :xiaomi_mimo_billing_plan)
  end

  defp pop_provider_billing_plan(%{} = provider_options) do
    {plan, provider_options} = Map.pop(provider_options, :xiaomi_mimo_billing_plan)

    case plan do
      nil -> Map.pop(provider_options, "xiaomi_mimo_billing_plan")
      plan -> {plan, provider_options}
    end
  end

  defp pop_provider_billing_plan(provider_options), do: {nil, provider_options}

  defp normalize_billing_plan(:token_plan), do: :token_plan
  defp normalize_billing_plan("token_plan"), do: :token_plan
  defp normalize_billing_plan(_plan), do: :pay_as_you_go

  defp effective_base_url(opts, billing_plan) do
    explicit_base_url = Keyword.get(opts, :base_url)
    plan_base_url = billing_plan_base_url(billing_plan)

    cond do
      explicit_base_url in [nil, ""] -> plan_base_url
      known_mimo_base_url?(explicit_base_url) -> plan_base_url
      true -> explicit_base_url
    end
  end

  defp billing_plan_base_url(:token_plan), do: @token_plan_base_url
  defp billing_plan_base_url(:pay_as_you_go), do: @pay_as_you_go_base_url

  defp known_mimo_base_url?(base_url) do
    base_url in [@pay_as_you_go_base_url, @token_plan_base_url]
  end

  defp anthropic_model_spec(%LLMDB.Model{} = model) do
    model
    |> Map.from_struct()
    |> Map.put(:provider, :anthropic)
  end

  defp anthropic_model_spec(%{} = model) do
    Map.put(model, :provider, :anthropic)
  end

  defp anthropic_model_spec(model_id) when is_binary(model_id) do
    %{provider: :anthropic, id: model_id}
  end

  defp anthropic_model_spec(model), do: model

  defp put_model_base_url(%{} = model, base_url), do: Map.put(model, :base_url, base_url)
  defp put_model_base_url(model, _base_url), do: model
end
