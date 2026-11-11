defmodule Ankole.AIGateway.WebSearch do
  @moduledoc """
  Standalone and native-Responses web search execution and citation projection.

  Both paths answer with `items` and `metadata`. Each item carries `url`,
  `title`, and `description`, plus `published_at` and `score` when the provider
  reports them.
  """

  alias Ankole.AIGateway.ModelProfiles
  alias Ankole.AIGateway.Providers
  alias Ankole.AIGateway.RequestExecution
  alias Ankole.AIGateway.Resolver
  alias Ankole.AIGateway.ResponseItems
  alias Ankole.Attrs

  @native_instructions "Search the web for the user's query and summarize the top relevant sources with inline URL citations."
  @max_query_chars 1024

  @spec create_web_search(
          String.t(),
          map(),
          keyword(),
          (String.t(), map(), keyword() -> {:ok, map()} | {:error, term()})
        ) :: {:ok, map()} | {:error, term()}
  def create_web_search(subject_uid, request, opts, create_response_fun)
      when is_map(request) and is_function(create_response_fun, 3) do
    request = Attrs.normalize_external_attrs(request)
    {respect_hosted?, call_opts} = Keyword.pop(opts, :respect_provider_hosted?, false)

    if respect_hosted? do
      create_hosted_aware(subject_uid, request, call_opts, create_response_fun)
    else
      create_standalone(subject_uid, request, call_opts)
    end
  end

  def create_web_search(_subject_uid, _request, _opts, _create_response_fun),
    do: {:error, :invalid_request_body}

  defp create_standalone(subject_uid, request, opts) do
    started_at = System.monotonic_time()

    with {:ok, runtime} <- Resolver.resolve_request_model(subject_uid, "web_search", request),
         :ok <- validate_request(request),
         {:ok, prepared_request} <- Providers.build_web_search_request(runtime, request),
         {:ok, upstream_response} <-
           RequestExecution.execute_prepared_request(runtime, prepared_request, opts) do
      items = Map.get(Map.fetch!(upstream_response, :body), "items") || []

      {:ok,
       RequestExecution.gateway_response(200, search_body(items, request, started_at), runtime)}
    end
  end

  defp create_hosted_aware(subject_uid, request, opts, create_response_fun) do
    with {:ok, hosted_caps} <- ModelProfiles.provider_hosted_capabilities(subject_uid) do
      if Map.get(hosted_caps, "web_search", true) do
        with :ok <- validate_request(request),
             {:ok, primary_runtime} <-
               Resolver.resolve_request_model(subject_uid, "llm", %{"model" => "primary"}) do
          if Providers.supports_native_web_search?(primary_runtime) do
            execute_native(subject_uid, request, opts, create_response_fun)
          else
            {:error, :model_profile_not_configured}
          end
        end
      else
        create_standalone(subject_uid, request, opts)
      end
    end
  end

  defp execute_native(subject_uid, request, opts, create_response_fun) do
    started_at = System.monotonic_time()
    query = String.trim(Map.fetch!(request, "query"))
    limit = Map.get(request, "limit") || 5

    responses_request = %{
      "model" => "primary",
      "store" => false,
      "instructions" => @native_instructions,
      "input" => query,
      "tools" => [%{"type" => "web_search"}],
      "tool_choice" => "required",
      "include" => ["web_search_call.action.sources"]
    }

    with {:ok, response} <- create_response_fun.(subject_uid, responses_request, opts) do
      case response.body["status"] do
        "completed" ->
          items = extract_native_results(response.body, limit)
          {:ok, %{response | body: search_body(items, request, started_at)}}

        _other ->
          {:error,
           {:incomplete_response,
            Map.take(response.body, ["status", "incomplete_details", "error", "usage"])}}
      end
    end
  end

  # `request_id` is the HTTP request ID, so it is present only for a call that
  # arrived over HTTP.
  defp search_body(items, request, started_at) do
    latency_ms =
      System.convert_time_unit(System.monotonic_time() - started_at, :native, :millisecond)

    metadata =
      Attrs.put_present(
        %{"query" => String.trim(Map.fetch!(request, "query")), "latency_ms" => latency_ms},
        "request_id",
        Logger.metadata()[:request_id]
      )

    %{"items" => items, "metadata" => metadata}
  end

  @doc false
  @spec extract_native_results(map(), pos_integer()) :: [map()]
  def extract_native_results(body, limit) do
    output = Map.get(body, "output") || []

    (extract_source_entries(output) ++ extract_citation_entries(output))
    |> deduplicate_by_url()
    |> project_results(limit)
  end

  defp extract_source_entries(output) do
    Enum.flat_map(output, fn
      %{"type" => "web_search_call", "action" => %{"sources" => sources}}
      when is_list(sources) ->
        Enum.flat_map(sources, fn
          %{"url" => url} = source when is_binary(url) and url != "" ->
            [
              %{
                "url" => url,
                "title" => source["title"],
                "description" => source["snippet"] || source["description"],
                "published_at" => source["published_at"] || source["publish_date"]
              }
            ]

          _other ->
            []
        end)

      _item ->
        []
    end)
  end

  defp extract_citation_entries(output) do
    output
    |> ResponseItems.message_content_parts()
    |> Enum.flat_map(fn
      %{"type" => "output_text", "annotations" => annotations} = part
      when is_list(annotations) ->
        text = part["text"] || ""

        Enum.flat_map(annotations, fn
          %{"type" => "url_citation", "url" => url} = citation
          when is_binary(url) and url != "" ->
            [
              %{
                "url" => url,
                "title" => citation["title"],
                "description" => citation_snippet(text, citation),
                "published_at" => nil
              }
            ]

          _other ->
            []
        end)

      _part ->
        []
    end)
  end

  defp deduplicate_by_url(entries) do
    Enum.reduce(entries, {[], %{}}, fn entry, {order, by_url} ->
      url = entry["url"]

      case Map.get(by_url, url) do
        nil ->
          {[url | order], Map.put(by_url, url, entry)}

        existing ->
          merged = %{
            "url" => url,
            "title" => existing["title"] || entry["title"],
            "description" => existing["description"] || entry["description"],
            "published_at" => existing["published_at"] || entry["published_at"]
          }

          {order, Map.put(by_url, url, merged)}
      end
    end)
  end

  defp project_results({order_rev, by_url}, limit) do
    order_rev
    |> Enum.reverse()
    |> Enum.take(limit)
    |> Enum.map(fn url ->
      entry = Map.fetch!(by_url, url)

      Attrs.put_present(
        %{
          "url" => url,
          "title" => entry["title"] || url,
          "description" => entry["description"] || ""
        },
        "published_at",
        entry["published_at"]
      )
    end)
  end

  defp citation_snippet(text, %{"start_index" => start_idx})
       when is_binary(text) and is_integer(start_idx) and start_idx >= 0 do
    # Extract the surrounding line from output_text so citations without source excerpts still carry context.
    text
    |> String.split("\n")
    |> Enum.reduce_while(0, fn line, cursor ->
      next_cursor = cursor + String.length(line) + 1

      if start_idx < next_cursor do
        {:halt, String.trim(line)}
      else
        {:cont, next_cursor}
      end
    end)
    |> case do
      snippet when is_binary(snippet) and snippet != "" ->
        Ankole.Text.utf8_prefix(snippet, 512)

      _empty_or_cursor ->
        Ankole.Text.utf8_prefix(String.trim(text), 512)
    end
  end

  defp citation_snippet(text, _citation) when is_binary(text) do
    Ankole.Text.utf8_prefix(String.trim(text), 512)
  end

  defp citation_snippet(_text, _citation), do: ""

  defp validate_request(request) do
    cond do
      not non_empty_string?(Map.get(request, "query")) ->
        {:error, :missing_query}

      String.length(String.trim(Map.get(request, "query"))) > @max_query_chars ->
        {:error, :invalid_query}

      not valid_limit?(Map.get(request, "limit")) ->
        {:error, :invalid_limit}

      true ->
        :ok
    end
  end

  defp valid_limit?(nil), do: true
  defp valid_limit?(value) when is_integer(value), do: value >= 1 and value <= 100
  defp valid_limit?(_value), do: false

  defp non_empty_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp non_empty_string?(_value), do: false
end
