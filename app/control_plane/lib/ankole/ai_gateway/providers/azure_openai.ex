defmodule Ankole.AIGateway.Providers.AzureOpenAI do
  @moduledoc """
  Azure OpenAI provider.
  """

  use Ankole.AIGateway.ProviderDSL

  alias Ankole.AIGateway.OpenAIRequestOptions
  alias Ankole.AIGateway.ProviderConnectionCheck
  alias Ankole.AIGateway.Providers
  alias Ankole.AIGateway.ReasoningEffort
  alias Ankole.AIGateway.UniversalAIRequest

  provider "azure_openai" do
    label(%{"default" => "Azure OpenAI", "zh-Hans-CN" => "Azure OpenAI"})

    setting(:api_key, encrypted: true, scope: :credential)
    setting(:endpoint_kind, default: "chat_completions")
    setting(:headers, type: :map, advanced: true)
    setting(:query_params, type: :map, advanced: true)
    setting(:api_version, default: "2025-04-01-preview", advanced: true)
    setting(:deployment)

    setting(:auth_scheme,
      type: :select,
      default: "api_key",
      options: ~w(api_key bearer auth_token),
      scope: :credential
    )

    setting(:reasoningEffort,
      type: :select,
      default: ReasoningEffort.default(),
      options: ReasoningEffort.values(),
      scope: :request
    )

    setting(:reasoningSummary,
      type: :select,
      options: OpenAIRequestOptions.reasoning_summary_values(),
      scope: :request,
      advanced: true
    )

    setting(:serviceTier, options: ~w(fast flex), scope: :request, advanced: true)
    setting(:strictJSONSchema, type: :boolean, scope: :request, advanced: true)

    setting(:textVerbosity,
      type: :select,
      options: OpenAIRequestOptions.text_verbosity_values(),
      scope: :request
    )

    setting(:truncation, scope: :request, advanced: true)

    language_model do
      upstream(:sse)
      api_resolver(:openai_chat_completions)
      prepare(:prepare_language_model)
      prepare_compaction(:prepare_compaction)
      supports_parallel_tool_calls()
    end
  end

  @doc """
  Builds an Azure OpenAI language-model request.

  Azure has several URL shapes for the same OpenAI protocol family. This
  function resolves only Azure endpoint/path/auth details; it still selects an
  OpenAI API resolver because the request and response bodies are OpenAI-shaped.
  """
  def prepare_language_model(ctx) do
    responses? = Providers.responses_endpoint?(ctx)
    options = Map.new(ctx.settings, fn {key, value} -> {Atom.to_string(key), value} end)

    with {:ok, path, include_model?} <- azure_response_path(ctx.runtime, responses?, options) do
      ctx
      |> UniversalAIRequest.new(path, Providers.openai_family_api_resolver(responses?),
        include_model: include_model?
      )
      |> put_auth(ctx)
      |> ReasoningEffort.put_provider_options(ctx,
        target: if(responses?, do: :reasoning, else: :reasoning_effort)
      )
      |> OpenAIRequestOptions.put_provider_options(
        if(responses?, do: :responses, else: :chat_completions)
      )
    end
  end

  @doc "Builds the standalone compact request for an Azure Responses endpoint."
  def prepare_compaction(ctx) do
    if Providers.responses_endpoint?(ctx) do
      with %UniversalAIRequest{} = request <- prepare_language_model(%{ctx | stream?: false}) do
        UniversalAIRequest.put_operation(request, :responses_compact)
      end
    else
      {:error, :responses_compaction_not_applicable}
    end
  end

  @doc """
  Prepares an Azure OpenAI connection check through the configured model catalog path.
  """
  @impl true
  def prepare_connection_check(ctx) when is_map(ctx) do
    with {:ok, path} <- azure_models_path(ctx) do
      headers =
        ctx
        |> UniversalAIRequest.raw_headers()
        |> put_auth(ctx)

      ProviderConnectionCheck.get(ctx, path, headers: headers)
    end
  end

  # Azure deployments may use either bearer tokens or the legacy `api-key`
  # header. A credential already prefixed with `Bearer ` is treated as bearer
  # even when the stored auth scheme is not explicit.
  defp put_auth(request, ctx) do
    scheme = ctx.settings[:auth_scheme]
    credential = ctx.settings[:api_key]

    cond do
      scheme in ["bearer", "auth_token", :bearer, :auth_token] ->
        UniversalAIRequest.bearer_auth(request, credential)

      is_binary(credential) and String.starts_with?(credential, "Bearer ") ->
        UniversalAIRequest.bearer_auth(request, credential)

      true ->
        UniversalAIRequest.api_key_header(request, "api-key", credential)
    end
  end

  # Azure OpenAI has at least three relevant URL families:
  # `/openai/v1/*`, traditional `/openai/deployments/*`, and Foundry endpoints.
  # Foundry is rejected here because it is not the same OpenAI-compatible wire
  # contract and should not be silently sent to an OpenAI resolver.
  defp azure_response_path(runtime, responses?, options) do
    base_url = options |> Map.get("base_url", "") |> to_string()
    api_version = Map.get(options, "api_version") || "2025-04-01-preview"
    deployment = Map.get(options, "deployment") || runtime["model"]

    cond do
      azure_foundry_base_url?(base_url) ->
        {:error, :unsupported_azure_foundry_endpoint}

      azure_v1_base_url?(base_url) and responses? ->
        {:ok, "responses", true}

      azure_v1_base_url?(base_url) ->
        {:ok, "chat/completions", true}

      responses? ->
        {:ok,
         azure_traditional_path(
           base_url,
           "responses?api-version=#{URI.encode_www_form(api_version)}"
         ), true}

      is_binary(deployment) and deployment != "" ->
        {:ok,
         azure_traditional_path(
           base_url,
           "deployments/#{URI.encode_www_form(deployment)}/chat/completions?api-version=#{URI.encode_www_form(api_version)}"
         ), false}

      true ->
        {:error, :missing_azure_deployment}
    end
  end

  # Model listing follows Azure endpoint shape but remains a raw helper call, so
  # no Rust API resolver is involved.
  defp azure_models_path(ctx) do
    base_url = ctx.settings[:base_url] |> to_string()
    api_version = ctx.settings[:api_version] || "2025-04-01-preview"
    query = "?api-version=#{URI.encode_www_form(api_version)}"

    cond do
      azure_v1_base_url?(base_url) ->
        {:ok, "models"}

      azure_openai_base_url?(base_url) ->
        {:ok, "models#{query}"}

      true ->
        {:ok, "openai/models#{query}"}
    end
  end

  # Some operators configure the base URL ending at the resource host, while
  # others include `/openai`. This helper prevents double-prefixing.
  defp azure_traditional_path(base_url, path) do
    if azure_openai_base_url?(base_url) do
      path
    else
      "openai/#{path}"
    end
  end

  defp azure_v1_base_url?(base_url) do
    case URI.parse(base_url) do
      %URI{path: path} when is_binary(path) -> String.contains?(path, "/openai/v1")
      _uri -> false
    end
  end

  defp azure_openai_base_url?(base_url) do
    case URI.parse(base_url) do
      %URI{path: path} when is_binary(path) ->
        path
        |> String.split("/", trim: true)
        |> Enum.member?("openai")

      _uri ->
        false
    end
  end

  defp azure_foundry_base_url?(base_url) do
    case URI.parse(base_url) do
      %URI{host: host} when is_binary(host) -> String.ends_with?(host, ".services.ai.azure.com")
      _uri -> false
    end
  end
end
