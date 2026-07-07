defmodule Ankole.AIGateway do
  @moduledoc """
  Control-plane owned AI provider gateway.

  AIGateway keeps provider credentials and provider differences in Elixir. Worker
  callers authenticate as an agent and send OpenResponses/OpenRouter-shaped
  requests to this module through the Phoenix API.
  """

  alias Ankole.AIGateway.MapUtils
  alias Ankole.AIGateway.CompactionArtifacts
  alias Ankole.AIGateway.Models
  alias Ankole.AIGateway.ModelProfiles
  alias Ankole.AIGateway.ModelSelectors
  alias Ankole.AIGateway.Providers
  alias Ankole.AIGateway.Resolver
  alias Ankole.AIGateway.StatefulLifecycle
  alias Ankole.AIGateway.UniversalAIRequest

  @stateful_http_fields ~w(previous_response_id conversation store)

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
    request = normalize_request_keys(request)

    with :ok <- reject_http_stateful_fields(request),
         {:ok, request} <- CompactionArtifacts.resolve_request_input_handles(agent_uid, request),
         {:ok, runtime} <- Resolver.resolve_request_model(agent_uid, "llm", request),
         {:ok, prepared_request} <-
           Providers.build_response_request(runtime, strip_noop_provider_fields(request),
             stream?: false
           ),
         {:ok, upstream_response} <- execute_prepared_request(runtime, prepared_request, opts) do
      {:ok, gateway_response(200, Map.fetch!(upstream_response, :body), runtime)}
    end
  end

  def create_response(_agent_uid, _request, _opts), do: {:error, :invalid_request_body}

  @doc """
  Retrieves one stored stateful response owned by the authenticated agent.
  """
  @spec retrieve_response(String.t(), binary()) :: {:ok, %{body: map()}} | {:error, term()}
  def retrieve_response(agent_uid, response_id) do
    StatefulLifecycle.retrieve_response(agent_uid, response_id)
  end

  @doc """
  Creates one manual stateful compaction response.
  """
  @spec compact_response(String.t(), map()) :: {:ok, %{body: map()}} | {:error, term()}
  def compact_response(agent_uid, request) when is_map(request) do
    StatefulLifecycle.compact_response(agent_uid, request)
  end

  def compact_response(_agent_uid, _request), do: {:error, :invalid_request_body}

  @doc false
  @spec record_tool_results(String.t(), map()) :: {:ok, %{body: map()}} | {:error, term()}
  def record_tool_results(agent_uid, request) when is_map(request) do
    StatefulLifecycle.record_tool_results(agent_uid, request)
  end

  def record_tool_results(_agent_uid, _request), do: {:error, :invalid_request_body}

  @doc false
  @spec open_sse_stream(String.t(), map(), keyword()) ::
          {:ok, Ankole.Kernel.UniversalAIClient.stream(), map()} | {:error, term()}
  def open_sse_stream(agent_uid, request, opts \\ [])

  def open_sse_stream(agent_uid, request, opts) when is_map(request) do
    request = normalize_request_keys(request)

    with :ok <- reject_http_stateful_fields(request),
         {:ok, request} <- CompactionArtifacts.resolve_request_input_handles(agent_uid, request),
         {:ok, runtime} <- Resolver.resolve_request_model(agent_uid, "llm", request),
         {:ok, prepared_request} <-
           Providers.build_response_request(runtime, strip_noop_provider_fields(request),
             stream?: true
           ) do
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
    with {:ok, prepared_request, stateful_context} <-
           prepare_websocket_stream_request(agent_uid, request) do
      case UniversalAIRequest.open_stream(prepared_request, :websocket_text, opts) do
        {:ok, stream, meta} ->
          {:ok, stream, put_stateful_stream_meta(meta, stateful_context)}

        {:error, reason} ->
          commit_stateful_open_error(stateful_context, reason)
          {:error, reason}
      end
    end
  end

  def open_websocket_stream(_agent_uid, _request, _opts), do: {:error, :invalid_request_body}

  @doc false
  @spec prepare_websocket_request(String.t(), map()) ::
          {:ok, UniversalAIRequest.t()} | {:error, term()}
  def prepare_websocket_request(agent_uid, request) when is_map(request) do
    with {:ok, prepared_request, _run_attrs} <-
           prepare_websocket_provider_request(agent_uid, request) do
      {:ok, prepared_request}
    end
  end

  def prepare_websocket_request(_agent_uid, _request), do: {:error, :invalid_request_body}

  defp prepare_websocket_stream_request(agent_uid, request) do
    with {:ok, prepared_request, run_attrs} <-
           prepare_websocket_provider_request(agent_uid, request),
         {:ok, stateful_context} <- maybe_start_websocket_stateful_run(run_attrs) do
      {:ok, prepared_request, stateful_context}
    end
  end

  defp prepare_websocket_provider_request(agent_uid, request) do
    StatefulLifecycle.prepare_websocket_provider_request(agent_uid, request)
  end

  defp strip_noop_provider_fields(request) do
    request
    |> Map.delete("service_tier")
  end

  defp maybe_start_websocket_stateful_run(run_attrs),
    do: StatefulLifecycle.start_websocket_run(run_attrs)

  defp put_stateful_stream_meta(meta, nil), do: meta

  defp put_stateful_stream_meta(meta, stateful_context),
    do: Map.put(meta, :stateful, stateful_context)

  defp commit_stateful_open_error(stateful_context, reason),
    do: StatefulLifecycle.commit_socket_open_error(stateful_context, reason)

  defp execute_prepared_request(_runtime, prepared_request, opts),
    do: UniversalAIRequest.request(prepared_request, opts)

  defp execute_web_fetch(%{"provider_kind" => "jina_reader"} = runtime, request, opts) do
    request
    |> Map.fetch!("urls")
    |> Enum.reduce_while({:ok, []}, fn url, {:ok, results} ->
      single_url_request = Map.put(request, "urls", [url])

      with {:ok, prepared_request} <-
             Providers.build_web_fetch_request(runtime, single_url_request),
           {:ok, upstream_response} <- execute_prepared_request(runtime, prepared_request, opts) do
        {:cont, {:ok, results ++ web_fetch_results(Map.fetch!(upstream_response, :body))}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, results} ->
        {:ok, %{"success" => Enum.all?(results, &is_nil(&1["error"])), "results" => results}}

      {:error, _reason} = error ->
        error
    end
  end

  defp execute_web_fetch(runtime, request, opts) do
    with {:ok, prepared_request} <- Providers.build_web_fetch_request(runtime, request),
         {:ok, upstream_response} <- execute_prepared_request(runtime, prepared_request, opts) do
      {:ok, Map.fetch!(upstream_response, :body)}
    end
  end

  defp web_fetch_results(%{"results" => results}) when is_list(results), do: results
  defp web_fetch_results(_body), do: []

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
  Creates a normalized web search result through AIGateway.
  """
  @spec create_web_search(String.t(), map(), keyword()) ::
          {:ok, gateway_response()} | {:error, term()}
  def create_web_search(agent_uid, request, opts \\ [])

  def create_web_search(agent_uid, request, opts) when is_map(request) do
    with {:ok, runtime} <- Resolver.resolve_request_model(agent_uid, "web_search", request),
         :ok <- validate_web_search_request(request),
         {:ok, prepared_request} <- Providers.build_web_search_request(runtime, request),
         {:ok, upstream_response} <- execute_prepared_request(runtime, prepared_request, opts) do
      {:ok, gateway_response(200, Map.fetch!(upstream_response, :body), runtime)}
    end
  end

  def create_web_search(_agent_uid, _request, _opts), do: {:error, :invalid_request_body}

  @doc """
  Creates normalized web fetch results through a provider-backed AIGateway path.
  """
  @spec create_web_fetch(String.t(), map(), keyword()) ::
          {:ok, gateway_response()} | {:error, term()}
  def create_web_fetch(agent_uid, request, opts \\ [])

  def create_web_fetch(agent_uid, request, opts) when is_map(request) do
    with {:ok, runtime} <- Resolver.resolve_request_model(agent_uid, "web_fetch", request),
         :ok <- validate_web_fetch_request(request),
         request = normalize_request_keys(request),
         {:ok, body} <- execute_web_fetch(runtime, request, opts) do
      {:ok, gateway_response(200, body, runtime)}
    end
  end

  def create_web_fetch(_agent_uid, _request, _opts), do: {:error, :invalid_request_body}

  @doc """
  Returns provider-backed web tool availability for an agent runtime.
  """
  @spec web_tools(String.t()) :: {:ok, map()}
  def web_tools(agent_uid) when is_binary(agent_uid) do
    {:ok,
     %{
       "web_search" => web_tool(agent_uid, "web_search"),
       "web_fetch" => web_tool(agent_uid, "web_fetch")
     }}
  end

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

  defp reject_http_stateful_fields(request) do
    request = normalize_request_keys(request)

    case Enum.find(@stateful_http_fields, &Map.has_key?(request, &1)) do
      "store" ->
        if request["store"] == false do
          :ok
        else
          {:error, {:stateful_http_field_forbidden, "store"}}
        end

      field when is_binary(field) ->
        {:error, {:stateful_http_field_forbidden, field}}

      nil ->
        :ok
    end
  end

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

  defp validate_web_search_request(request) do
    request = normalize_request_keys(request)

    cond do
      not non_empty_string?(Map.get(request, "query")) ->
        {:error, :missing_query}

      String.length(String.trim(Map.get(request, "query"))) > 500 ->
        {:error, :invalid_query}

      not valid_web_limit?(Map.get(request, "limit")) ->
        {:error, :invalid_limit}

      true ->
        :ok
    end
  end

  defp validate_web_fetch_request(request) do
    request = normalize_request_keys(request)

    cond do
      not Map.has_key?(request, "urls") ->
        {:error, :missing_urls}

      not valid_extract_urls?(Map.get(request, "urls")) ->
        {:error, :invalid_urls}

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

  defp valid_web_limit?(nil), do: true
  defp valid_web_limit?(value) when is_integer(value), do: value >= 1 and value <= 100
  defp valid_web_limit?(_value), do: false

  defp valid_extract_urls?(urls) when is_list(urls) and urls != [] and length(urls) <= 5,
    do: Enum.all?(urls, &safe_web_url?/1)

  defp valid_extract_urls?(_urls), do: false

  defp safe_web_url?(url) when is_binary(url) do
    case URI.new(String.trim(url)) do
      {:ok, %URI{scheme: "https", host: host}} when is_binary(host) and host != "" ->
        safe_web_host?(String.downcase(host))

      _uri ->
        false
    end
  end

  defp safe_web_url?(_url), do: false

  defp safe_web_host?(host) do
    cond do
      host in ["localhost", "metadata", "metadata.google.internal"] -> false
      String.ends_with?(host, ".localhost") -> false
      ip_address?(host) -> public_ip_address?(host)
      true -> true
    end
  end

  defp ip_address?(host), do: match?({:ok, _address}, :inet.parse_address(to_charlist(host)))

  defp public_ip_address?(host) do
    case :inet.parse_address(to_charlist(host)) do
      {:ok, address} -> public_ip_tuple?(address)
      {:error, _reason} -> false
    end
  end

  defp public_ip_tuple?({10, _, _, _}), do: false
  defp public_ip_tuple?({127, _, _, _}), do: false
  defp public_ip_tuple?({169, 254, _, _}), do: false
  defp public_ip_tuple?({172, second, _, _}) when second >= 16 and second <= 31, do: false
  defp public_ip_tuple?({192, 168, _, _}), do: false
  defp public_ip_tuple?({0, _, _, _}), do: false
  defp public_ip_tuple?({100, second, _, _}) when second >= 64 and second <= 127, do: false
  defp public_ip_tuple?({_, _, _, _}), do: true
  defp public_ip_tuple?({0, 0, 0, 0, 0, 0, 0, 1}), do: false

  defp public_ip_tuple?({first, _, _, _, _, _, _, _}) when first >= 0xFC00 and first <= 0xFDFF,
    do: false

  defp public_ip_tuple?({first, _, _, _, _, _, _, _}) when first >= 0xFE80 and first <= 0xFEBF,
    do: false

  defp public_ip_tuple?({_a, _b, _c, _d, _e, _f, _g, _h}), do: true

  defp non_empty_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp non_empty_string?(_value), do: false

  defp normalize_request_keys(map) when is_map(map) do
    MapUtils.normalize_request_keys(map)
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

  defp web_tool(agent_uid, capability) do
    profile = capability

    case ModelProfiles.resolve_runtime_profile(agent_uid, profile) do
      {:ok, runtime} ->
        %{
          "available" => true,
          "model" => ModelSelectors.public_selector(capability, profile),
          "provider_id" => runtime["provider_id"],
          "provider_kind" => runtime["provider_kind"]
        }

      {:error, reason} ->
        %{
          "available" => false,
          "reason" => unavailable_web_tool_reason(reason)
        }
    end
  end

  defp unavailable_web_tool_reason(:model_profile_not_configured),
    do: "model_profile_not_configured"

  defp unavailable_web_tool_reason(:invalid_model_profile), do: "invalid_model_profile"
  defp unavailable_web_tool_reason(:agent_not_found), do: "agent_not_found"
  defp unavailable_web_tool_reason(:provider_disabled), do: "provider_disabled"
  defp unavailable_web_tool_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp unavailable_web_tool_reason(reason), do: inspect(reason)
end
