defmodule Ankole.AIGateway do
  @moduledoc """
  Control-plane owned AI provider gateway.

  AIGateway keeps provider credentials and provider differences in Elixir. Worker
  callers authenticate as an agent and send OpenResponses/OpenRouter-shaped
  requests to this module through the Phoenix API.
  """

  alias Ankole.AIGateway.Models
  alias Ankole.AIGateway.Providers
  alias Ankole.AIGateway.Resolver
  alias Ankole.AIGateway.UniversalAIRequest

  @type gateway_response :: %{
          required(:status) => pos_integer(),
          required(:body) => map(),
          required(:model_ref) => map()
        }

  @doc """
  Creates one stateless OpenResponses response.

  The call resolves the agent-visible selector, prepares a provider-owned
  UniversalAIRequest spec, calls the UniversalAIClient, and normalizes the result back
  into the AIGateway response body.
  """
  @spec create_response(String.t(), map(), keyword()) ::
          {:ok, gateway_response()} | {:error, term()}
  def create_response(agent_uid, request, opts \\ [])

  def create_response(agent_uid, request, opts) when is_map(request) do
    with {:ok, runtime} <- Resolver.resolve_request_model(agent_uid, "llm", request),
         {:ok, prepared_request} <-
           Providers.build_response_request(runtime, request, stream?: false),
         {:ok, upstream_response} <- execute_prepared_request(runtime, prepared_request, opts) do
      {:ok, gateway_response(200, Map.fetch!(upstream_response, :body), runtime)}
    end
  end

  def create_response(_agent_uid, _request, _opts), do: {:error, :invalid_request_body}

  @doc false
  @spec open_sse_stream(String.t(), map(), keyword()) ::
          {:ok, Ankole.Kernel.UniversalAIClient.stream(), map()} | {:error, term()}
  def open_sse_stream(agent_uid, request, opts \\ [])

  def open_sse_stream(agent_uid, request, opts) when is_map(request) do
    with {:ok, runtime} <- Resolver.resolve_request_model(agent_uid, "llm", request),
         {:ok, prepared_request} <-
           Providers.build_response_request(runtime, request, stream?: true) do
      UniversalAIRequest.open_stream(prepared_request, :sse, opts)
    else
      {:error, _reason} = error -> error
      reason -> {:error, reason}
    end
  end

  def open_sse_stream(_agent_uid, _request, _opts), do: {:error, :invalid_request_body}

  @doc false
  @spec open_websocket_stream(String.t(), map(), keyword()) ::
          {:ok, Ankole.Kernel.UniversalAIClient.stream(), map()} | {:error, term()}
  def open_websocket_stream(agent_uid, request, opts \\ [])

  def open_websocket_stream(agent_uid, request, opts) when is_map(request) do
    with {:ok, runtime} <- Resolver.resolve_request_model(agent_uid, "llm", request),
         {:ok, prepared_request} <-
           Providers.build_response_request(runtime, request, stream?: true) do
      UniversalAIRequest.open_stream(prepared_request, :websocket_text, opts)
    else
      {:error, _reason} = error -> error
      reason -> {:error, reason}
    end
  end

  def open_websocket_stream(_agent_uid, _request, _opts), do: {:error, :invalid_request_body}

  defp execute_prepared_request(_runtime, prepared_request, opts),
    do: UniversalAIRequest.request(prepared_request, opts)

  @doc """
  Creates embeddings with a normalized list response shape.

  Request validation happens before provider dispatch because invalid local
  shape should not become an upstream provider call or failover candidate.
  """
  @spec create_embeddings(String.t(), map(), keyword()) ::
          {:ok, gateway_response()} | {:error, term()}
  def create_embeddings(agent_uid, request, opts \\ [])

  def create_embeddings(agent_uid, request, opts) when is_map(request) do
    with {:ok, runtime} <- Resolver.resolve_request_model(agent_uid, "embedding", request),
         :ok <- validate_embeddings_request(request),
         {:ok, prepared_request} <- Providers.build_embeddings_request(runtime, request),
         {:ok, upstream_response} <- execute_prepared_request(runtime, prepared_request, opts) do
      {:ok, gateway_response(200, Map.fetch!(upstream_response, :body), runtime)}
    end
  end

  def create_embeddings(_agent_uid, _request, _opts), do: {:error, :invalid_request_body}

  @doc """
  Creates a rerank result with an OpenRouter-compatible public shape.

  Rerank uses the same model resolver as LLM calls, but requires a provider that
  explicitly supports the `rerank` capability.
  """
  @spec create_rerank(String.t(), map(), keyword()) ::
          {:ok, gateway_response()} | {:error, term()}
  def create_rerank(agent_uid, request, opts \\ [])

  def create_rerank(agent_uid, request, opts) when is_map(request) do
    with {:ok, runtime} <- Resolver.resolve_request_model(agent_uid, "rerank", request),
         :ok <- validate_rerank_request(request),
         {:ok, prepared_request} <- Providers.build_rerank_request(runtime, request),
         {:ok, upstream_response} <- execute_prepared_request(runtime, prepared_request, opts) do
      {:ok, gateway_response(200, Map.fetch!(upstream_response, :body), runtime)}
    end
  end

  def create_rerank(_agent_uid, _request, _opts), do: {:error, :invalid_request_body}

  @doc """
  Lists OpenRouter-shaped model selectors available through AIGateway.
  """
  @spec list_models(String.t(), String.t(), map()) :: {:ok, map()}
  defdelegate list_models(subject_uid, subject_type, params \\ %{}), to: Models

  @doc """
  Returns whether a request asked for an SSE response.
  """
  @spec stream_requested?(map()) :: boolean()
  def stream_requested?(%{"stream" => true}), do: true
  def stream_requested?(%{stream: true}), do: true
  def stream_requested?(_request), do: false

  defp validate_embeddings_request(request) do
    request = normalize_request_keys(request)

    cond do
      not Map.has_key?(request, "input") ->
        {:error, :missing_input}

      embedding_input?(Map.get(request, "input")) ->
        :ok

      true ->
        {:error, :invalid_embedding_input}
    end
  end

  defp validate_rerank_request(request) do
    request = normalize_request_keys(request)

    cond do
      not non_empty_string?(Map.get(request, "query")) ->
        {:error, :missing_query}

      not rerank_documents?(Map.get(request, "documents")) ->
        {:error, :invalid_documents}

      not valid_top_n?(Map.get(request, "top_n")) ->
        {:error, :invalid_top_n}

      true ->
        :ok
    end
  end

  defp embedding_input?(input) when is_binary(input), do: String.trim(input) != ""

  defp embedding_input?(input) when is_list(input) and input != [] do
    Enum.all?(input, fn
      value when is_binary(value) -> true
      value when is_integer(value) -> true
      value when is_map(value) -> true
      value when is_list(value) -> Enum.all?(value, &is_integer/1)
      _value -> false
    end)
  end

  defp embedding_input?(_input), do: false

  defp rerank_documents?(documents) when is_list(documents) and documents != [] do
    Enum.all?(documents, fn
      document when is_binary(document) -> String.trim(document) != ""
      document when is_map(document) -> map_size(document) > 0
      _document -> false
    end)
  end

  defp rerank_documents?(_documents), do: false

  defp valid_top_n?(nil), do: true
  defp valid_top_n?(value) when is_integer(value), do: value > 0
  defp valid_top_n?(_value), do: false

  defp non_empty_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp non_empty_string?(_value), do: false

  defp normalize_request_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  # Keeps transport response data separate from model resolution facts. The body
  # must stay provider-contract compatible; internal trace facts belong in
  # `model_ref`, telemetry, or durable turn metadata.
  defp gateway_response(status, body, runtime) do
    %{
      status: status,
      body: body,
      model_ref: %{
        "provider_id" => runtime["provider_id"],
        "provider_kind" => runtime["provider_kind"],
        "model" => runtime["model"],
        "selector" => runtime["selector"],
        "capability" => runtime["capability"]
      }
    }
  end
end
