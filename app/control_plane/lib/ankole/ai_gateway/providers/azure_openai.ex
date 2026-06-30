defmodule Ankole.AIGateway.Providers.AzureOpenAI do
  @moduledoc """
  Azure OpenAI provider.
  """

  use Ankole.AIGateway.ProviderDSL

  alias Ankole.AIGateway.ReasoningEffort
  alias Ankole.AIGateway.UniversalAIRequest

  provider "azure_openai" do
    label(%{"default" => "Azure OpenAI", "zh-Hans-CN" => "Azure OpenAI"})

    setting(:api_key, encrypted: true)
    setting(:endpoint_kind, default: "chat_completions")
    setting(:headers, type: :map)
    setting(:query_params, type: :map)
    setting(:api_version, default: "2025-04-01-preview")
    setting(:deployment)
    setting(:auth_scheme, default: "api_key")
    setting(:include_usage, type: :boolean)
    setting(:supports_structured_outputs, type: :boolean)

    setting(:reasoningEffort, scope: :request)
    setting(:reasoningSummary, scope: :request)
    setting(:serviceTier, scope: :request)
    setting(:strictJsonSchema, scope: :request)
    setting(:textVerbosity, scope: :request)
    setting(:truncation, scope: :request)

    language_model do
      upstream(:sse)
      api_resolver(:openai_chat_completions)
      prepare(:prepare_language_model)
    end
  end

  @doc """
  Builds an Azure OpenAI language-model request.

  Azure has several URL shapes for the same OpenAI protocol family. This
  function resolves only Azure endpoint/path/auth details; it still selects an
  OpenAI API resolver because the request and response bodies are OpenAI-shaped.
  """
  def prepare_language_model(ctx) do
    endpoint_mode = endpoint_kind(ctx)
    options = Map.new(ctx.settings, fn {key, value} -> {Atom.to_string(key), value} end)

    with {:ok, path, include_model?} <- azure_response_path(ctx.runtime, endpoint_mode, options) do
      ctx
      |> UniversalAIRequest.new(path, resolver_for_endpoint(endpoint_mode),
        include_model: include_model?
      )
      |> put_auth(ctx)
      |> ReasoningEffort.put_provider_options(ctx)
    end
  end

  @doc """
  Checks Azure OpenAI connectivity through the configured model catalog path.
  """
  @impl true
  def check_connection(ctx) when is_map(ctx) do
    with {:ok, path} <- azure_models_path(ctx) do
      headers =
        ctx
        |> UniversalAIRequest.raw_headers()
        |> put_auth(ctx)

      with {:ok, %{"status" => status, "body" => body}} when status in 200..299 <-
             UniversalAIRequest.raw_get(ctx, path, headers: headers) do
        {:ok, body}
      else
        {:ok, %{"status" => status, "body" => body}} ->
          {:error, {:provider_connection_check_failed, status, body}}

        {:error, _reason} = error ->
          error
      end
    end
  end

  # Azure can front either the Responses API or Chat Completions. The resolver
  # follows the selected endpoint because the native Rust side normalizes those
  # two OpenAI stream formats differently.
  defp endpoint_kind(ctx) do
    case ctx.settings[:endpoint_kind] do
      "responses" -> "responses"
      _kind -> "chat_completions"
    end
  end

  defp resolver_for_endpoint("responses"), do: :openai_responses
  defp resolver_for_endpoint(_mode), do: :openai_chat_completions

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
  defp azure_response_path(runtime, endpoint_mode, options) do
    base_url = options |> Map.get("base_url", "") |> to_string()
    api_version = Map.get(options, "api_version") || "2025-04-01-preview"
    deployment = Map.get(options, "deployment") || runtime["model"]

    cond do
      azure_foundry_base_url?(base_url) ->
        {:error, :unsupported_azure_foundry_endpoint}

      azure_v1_base_url?(base_url) and endpoint_mode == "responses" ->
        {:ok, "responses", true}

      azure_v1_base_url?(base_url) and endpoint_mode == "chat_completions" ->
        {:ok, "chat/completions", true}

      endpoint_mode == "responses" ->
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
