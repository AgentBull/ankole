defmodule Ankole.AIGateway.Providers.AzureOpenAI do
  @moduledoc """
  Provider implementation for Azure OpenAI.

  Azure OpenAI is not just an OpenAI base URL override. Traditional deployments
  put the deployment name and API version in the URL and often use `api-key`;
  newer `/openai/v1` endpoints behave more like OpenAI and may use bearer auth.
  """

  @behaviour Ankole.AIGateway.Provider

  alias Ankole.AIGateway.Providers.OpenAICompatible
  alias Ankole.AIGateway.Request

  @impl true
  def provider_id, do: "azure_openai"

  @impl true
  def label, do: "Azure OpenAI"

  @impl true
  def capabilities, do: ["llm"]

  @impl true
  def endpoint_modes, do: ["responses", "chat_completions"]

  @impl true
  def provider_strategy, do: "azure_openai"

  @impl true
  def default_base_url, do: nil

  @impl true
  def default_http_protocol, do: "http2"

  @impl true
  def credential_schemes, do: ["api_key", "auth_token", "bearer"]

  @impl true
  def connection_option_keys,
    do:
      ~w(http_protocol endpoint_kind headers query_params api_version deployment auth_scheme include_usage supports_structured_outputs)

  @impl true
  def runtime_provider_option_keys,
    do: ~w(reasoningEffort reasoningSummary serviceTier strictJsonSchema textVerbosity truncation)

  @impl true
  def model_catalog_policy, do: "known_or_custom"

  @impl true
  def response_endpoint_mode(%{"connection_options" => options}) do
    case Map.get(options, "endpoint_kind") do
      "responses" -> "responses"
      _kind -> "chat_completions"
    end
  end

  def response_endpoint_mode(_runtime), do: "chat_completions"

  @impl true
  def build_response_request(runtime, request, opts) do
    stream? = Keyword.get(opts, :stream?, false)

    with {:ok, request} <-
           Request.build_azure_openai_response_request(
             runtime,
             request,
             response_endpoint_mode(runtime),
             stream?: stream?
           ) do
      {:ok, maybe_stream_request(request, stream?)}
    end
  end

  @impl true
  def normalize_response_body(runtime, upstream_request, upstream_response),
    do: OpenAICompatible.normalize_response_body(runtime, upstream_request, upstream_response)

  @impl true
  def put_headers(headers, _runtime), do: headers

  @impl true
  def put_auth_headers(headers, %{"credential" => credential} = runtime)
      when is_binary(credential) do
    scheme =
      get_in(runtime, ["connection_options", "auth_scheme"]) ||
        runtime["credential_mode"] ||
        "api_key"

    # Azure accepts both account API keys and Entra/OAuth bearer tokens. A
    # prefixed `Bearer ...` credential is normalized so operators can paste the
    # token form they already have without duplicating the prefix on the wire.
    cond do
      scheme in ["bearer", "auth_token"] or String.starts_with?(credential, "Bearer ") ->
        Map.put(
          headers,
          "authorization",
          "Bearer #{String.replace_prefix(credential, "Bearer ", "")}"
        )

      true ->
        Map.put(headers, "api-key", credential)
    end
  end

  def put_auth_headers(headers, _runtime), do: headers

  @impl true
  def stream_init(runtime, upstream_request),
    do: OpenAICompatible.stream_init(runtime, upstream_request)

  @impl true
  def decode_stream_message(runtime, upstream_request, state, message),
    do: OpenAICompatible.decode_stream_message(runtime, upstream_request, state, message)

  @impl true
  def finish_stream(runtime, upstream_request, state),
    do: OpenAICompatible.finish_stream(runtime, upstream_request, state)

  defp maybe_stream_request(request, false), do: request

  defp maybe_stream_request(request, true) do
    request
    |> put_in([:headers, "accept"], "text/event-stream")
    |> Map.put(:stream?, true)
  end
end
