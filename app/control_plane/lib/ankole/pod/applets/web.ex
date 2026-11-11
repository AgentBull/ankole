defmodule Ankole.Pod.Applets.Web do
  @moduledoc "Stateless Applet web search and web page extraction through AIGateway."

  alias Ankole.AIGateway
  alias Ankole.Pod.Access

  @default_search_limit 5
  @max_search_limit 100
  @max_query_chars 1024
  @default_max_chars 40_000
  @max_fetch_chars 200_000
  @max_fetch_urls 5
  @truncation_marker "\n...\n"
  @min_head_tail_budget 24

  def search(%Ankole.AuthZ.Actor{} = actor, options) when is_map(options) do
    with {:ok, principal} <- Access.write(actor.turn_authority, fn -> Access.principal(actor) end) do
      do_search(principal, options)
    end
  end

  def search(_actor, _options), do: {:error, search_error(:invalid_request)}

  defp do_search(principal, options) do
    with {:ok, query, limit} <- validate_search_options(options),
         {:ok, %{body: body}} <-
           AIGateway.create_web_search(
             principal.uid,
             %{"model" => "web_search.default", "query" => query, "limit" => limit},
             respect_provider_hosted?: true,
             caller: "pod_applet",
             request_context: human_context(principal)
           ) do
      results =
        (body["items"] || [])
        |> Enum.take(limit)
        |> Enum.with_index(1)
        |> Enum.map(fn {item, idx} ->
          %{
            title: item["title"] || item["url"] || "",
            url: item["url"] || "",
            snippet: item["description"] || "",
            position: idx
          }
          |> maybe_put(:publishedAt, item["published_at"])
          |> maybe_put(:score, item["score"])
        end)

      {:ok, %{query: query, results: results}}
    else
      {:error, reason} -> {:error, search_error(reason)}
    end
  end

  def fetch(%Ankole.AuthZ.Actor{} = actor, options) when is_map(options) do
    with {:ok, principal} <- Access.write(actor.turn_authority, fn -> Access.principal(actor) end) do
      do_fetch(principal, options)
    end
  end

  def fetch(_actor, _options), do: {:error, fetch_error(:invalid_request)}

  defp do_fetch(principal, options) do
    with {:ok, urls, max_chars} <- validate_fetch_options(options),
         unique_urls = Enum.uniq(urls),
         {:ok, %{body: body}} <-
           AIGateway.create_web_fetch(
             principal.uid,
             %{"model" => "web_fetch.default", "urls" => unique_urls},
             caller: "pod_applet",
             request_context: human_context(principal)
           ) do
      by_url = index_fetched_pages(unique_urls, body["results"] || [])

      raw_pages =
        Enum.map(urls, fn url ->
          page = Map.get(by_url, url, %{"url" => url, "error" => "No web fetch result."})
          text = if is_binary(page["text"]), do: page["text"], else: ""
          {url, page, text, String.length(text)}
        end)

      allocations = allocate_chars(Enum.map(raw_pages, &elem(&1, 3)), max_chars)

      results =
        raw_pages
        |> Enum.zip(allocations)
        |> Enum.map(fn {{url, page, text, total_chars}, allocated} ->
          truncated = total_chars > allocated
          excerpt = if truncated, do: slice_head_and_tail(text, allocated), else: text
          warning = AIGateway.web_fetch_render_warning(page)

          %{
            url: page["url"] || url,
            title: page["title"] || "",
            text: excerpt,
            truncated: truncated
          }
          |> maybe_put(:renderWarning, warning)
          |> maybe_put(:error, page["error"])
        end)

      {:ok,
       %{
         success: Enum.all?(results, &is_nil(Map.get(&1, :error))),
         results: results
       }}
    else
      {:error, reason} -> {:error, fetch_error(reason)}
    end
  end

  defp index_fetched_pages(unique_urls, results) when is_list(results) do
    if length(results) == length(unique_urls) and
         Enum.all?(results, &(is_map(&1) and not is_binary(&1["url"]))) do
      Map.new(Enum.zip(unique_urls, results))
    else
      Enum.reduce(results, %{}, fn
        %{"url" => url} = item, acc when is_binary(url) and url != "" ->
          Map.put_new(acc, url, item)

        _other, acc ->
          acc
      end)
    end
  end

  defp index_fetched_pages(_unique_urls, _results), do: %{}

  defp human_context(%{type: :human, uid: uid}), do: %{"human_uid" => uid}
  defp human_context(_principal), do: %{}

  defp validate_search_options(options) do
    unknown = Map.keys(options) -- ["query", "limit"]
    raw_query = Map.get(options, "query")
    limit = Map.get(options, "limit", @default_search_limit)

    cond do
      unknown != [] ->
        {:error, :invalid_request}

      not is_binary(raw_query) ->
        {:error, :invalid_request}

      String.trim(raw_query) == "" ->
        {:error, :invalid_request}

      String.length(String.trim(raw_query)) > @max_query_chars ->
        {:error, :invalid_request}

      not (is_integer(limit) and limit in 1..@max_search_limit) ->
        {:error, :invalid_request}

      true ->
        {:ok, String.trim(raw_query), limit}
    end
  end

  defp validate_fetch_options(options) do
    unknown = Map.keys(options) -- ["urls", "maxChars"]
    urls = Map.get(options, "urls")
    max_chars = Map.get(options, "maxChars", @default_max_chars)

    cond do
      unknown != [] ->
        {:error, :invalid_request}

      not (is_list(urls) and urls != [] and length(urls) <= @max_fetch_urls) ->
        {:error, :invalid_request}

      not Enum.all?(urls, &(is_binary(&1) and String.trim(&1) != "")) ->
        {:error, :invalid_request}

      not (is_integer(max_chars) and max_chars in 1..@max_fetch_chars) ->
        {:error, :invalid_request}

      true ->
        {:ok, urls, max_chars}
    end
  end

  # Water-filling character budget across fetched pages so short pages never waste quota needed by longer pages.
  defp allocate_chars(lengths, budget) do
    indexed = Enum.with_index(lengths)
    allocations = do_allocate_chars(indexed, budget, %{})
    Enum.map(0..(length(lengths) - 1)//1, &Map.get(allocations, &1, 0))
  end

  defp do_allocate_chars([], _budget, acc), do: acc

  defp do_allocate_chars(pending, budget, acc) do
    count = length(pending)
    share = div(budget, count)
    {small, large} = Enum.split_with(pending, fn {len, _idx} -> len <= share end)

    if small == [] do
      rem_chars = rem(budget, count)

      pending
      |> Enum.with_index()
      |> Enum.reduce(acc, fn {{_len, idx}, pos}, map ->
        Map.put(map, idx, share + if(pos < rem_chars, do: 1, else: 0))
      end)
    else
      {next_budget, next_acc} =
        Enum.reduce(small, {budget, acc}, fn {len, idx}, {rem_b, map} ->
          {rem_b - len, Map.put(map, idx, len)}
        end)

      do_allocate_chars(large, next_budget, next_acc)
    end
  end

  defp slice_head_and_tail(_text, budget) when budget <= 0, do: ""

  defp slice_head_and_tail(text, budget) when budget < @min_head_tail_budget do
    String.slice(text, 0, budget)
  end

  defp slice_head_and_tail(text, budget) do
    marker_len = String.length(@truncation_marker)
    content_budget = budget - marker_len
    total_len = String.length(text)
    head_target = div(content_budget * 7, 10)
    min_tail = content_budget - head_target

    head = snap_head_to_line(String.slice(text, 0, head_target), div(head_target, 2))
    tail_budget = content_budget - String.length(head)

    tail =
      text
      |> String.slice(total_len - tail_budget, tail_budget)
      |> snap_tail_to_line(div(min_tail, 2))

    head <> @truncation_marker <> tail
  end

  defp snap_head_to_line(chunk, min_keep) do
    case String.split(chunk, "\n") do
      [_single_line] ->
        chunk

      lines ->
        candidate = lines |> Enum.drop(-1) |> Enum.join("\n")
        if String.length(candidate) >= min_keep, do: candidate, else: chunk
    end
  end

  defp snap_tail_to_line(chunk, min_keep) do
    case String.split(chunk, "\n", parts: 2) do
      [_single_line] ->
        chunk

      [_dropped_partial, candidate] ->
        if String.length(candidate) >= min_keep, do: candidate, else: chunk
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp search_error({:agent_token_quota_exceeded, _}) do
    %{
      status: 429,
      code: "agent_token_quota_exceeded",
      message: "agent_token_quota_exceeded",
      details: nil
    }
  end

  defp search_error(reason)
       when reason in [
              :model_profile_not_configured,
              :system_principal_missing,
              :invalid_model_profile
            ] do
    %{
      status: 422,
      code: "web_search_not_configured",
      message: "web_search_not_configured",
      details: nil
    }
  end

  defp search_error({name, _})
       when name in [
              :unknown_model_selector,
              :invalid_model_profile,
              :model_profile_capability_mismatch
            ] do
    %{
      status: 422,
      code: "web_search_not_configured",
      message: "web_search_not_configured",
      details: nil
    }
  end

  defp search_error(reason)
       when reason in [
              :invalid_request,
              :invalid_request_body,
              :missing_query,
              :invalid_query,
              :invalid_limit
            ] do
    %{status: 400, code: "invalid_request", message: "invalid_request", details: nil}
  end

  defp search_error(_reason) do
    %{
      status: 502,
      code: "web_search_unavailable",
      message: "web_search_unavailable",
      details: nil
    }
  end

  defp fetch_error({:agent_token_quota_exceeded, _}) do
    %{
      status: 429,
      code: "agent_token_quota_exceeded",
      message: "agent_token_quota_exceeded",
      details: nil
    }
  end

  defp fetch_error(reason)
       when reason in [
              :model_profile_not_configured,
              :system_principal_missing,
              :invalid_model_profile
            ] do
    %{
      status: 422,
      code: "web_fetch_not_configured",
      message: "web_fetch_not_configured",
      details: nil
    }
  end

  defp fetch_error({name, _})
       when name in [
              :unknown_model_selector,
              :invalid_model_profile,
              :model_profile_capability_mismatch
            ] do
    %{
      status: 422,
      code: "web_fetch_not_configured",
      message: "web_fetch_not_configured",
      details: nil
    }
  end

  defp fetch_error(reason)
       when reason in [:invalid_request, :invalid_request_body, :missing_urls, :invalid_urls] do
    %{status: 400, code: "invalid_request", message: "invalid_request", details: nil}
  end

  defp fetch_error(_reason) do
    %{status: 502, code: "web_fetch_unavailable", message: "web_fetch_unavailable", details: nil}
  end
end
