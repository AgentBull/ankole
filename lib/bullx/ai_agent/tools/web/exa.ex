defmodule BullX.AIAgent.Tools.Web.Exa do
  @moduledoc """
  Exa adapter for BullX AIAgent web search and extraction tools.

  The adapter translates Exa's response fields into BullX's normalized
  `title`/`url`/`snippet` or extracted-text result shape.
  """

  alias BullX.AIAgent.Tools.Web

  @search_url "https://api.exa.ai/search"
  @contents_url "https://api.exa.ai/contents"

  def available?(_kind), do: not is_nil(Web.api_key(:exa))

  def search(%{query: query, limit: limit}, runtime_seed) do
    body = %{
      "query" => query,
      "type" => "auto",
      "numResults" => limit,
      "contents" => %{"highlights" => true}
    }

    [url: @search_url, json: body, headers: auth_headers(), retry: false]
    |> Keyword.merge(Web.req_options(runtime_seed))
    |> Req.post()
    |> Web.http_result()
    |> case do
      {:ok, response} ->
        {:ok,
         %{"success" => true, "query" => query, "results" => search_results(response, limit)}}

      {:error, error} ->
        {:error, error}
    end
  end

  def extract(%{urls: urls}, runtime_seed) do
    body = %{"urls" => urls, "text" => true}

    [url: @contents_url, json: body, headers: auth_headers(), retry: false]
    |> Keyword.merge(Web.req_options(runtime_seed))
    |> Req.post()
    |> Web.http_result()
    |> case do
      {:ok, response} -> {:ok, %{"success" => true, "results" => extract_results(response)}}
      {:error, error} -> {:error, error}
    end
  end

  defp auth_headers, do: [{"x-api-key", Web.api_key(:exa)}]

  defp search_results(%{"results" => results}, limit) when is_list(results) do
    results
    |> Enum.take(limit)
    |> Enum.map(&search_result/1)
  end

  defp search_results(_response, _limit), do: []

  defp search_result(%{} = item) do
    %{
      "title" => string_value(item, "title"),
      "url" => string_value(item, "url"),
      "snippet" => exa_snippet(item)
    }
    |> maybe_put_position(item)
  end

  defp exa_snippet(%{"highlights" => highlights}) when is_list(highlights) do
    highlights
    |> Enum.filter(&is_binary/1)
    |> Enum.join("\n")
  end

  defp exa_snippet(%{"text" => text}) when is_binary(text), do: text
  defp exa_snippet(%{"snippet" => snippet}) when is_binary(snippet), do: snippet
  defp exa_snippet(_item), do: ""

  defp extract_results(%{"results" => results} = response) when is_list(results) do
    status_by_url = status_by_url(Map.get(response, "statuses"))

    Enum.map(results, fn item ->
      url = string_value(item, "url")

      %{
        "url" => url,
        "title" => string_value(item, "title"),
        "text" => string_value(item, "text")
      }
      |> maybe_put_error(Map.get(status_by_url, url))
    end)
  end

  defp extract_results(_response), do: []

  defp status_by_url(statuses) when is_list(statuses) do
    statuses
    |> Enum.filter(&is_map/1)
    |> Map.new(fn status -> {string_value(status, "url"), status} end)
  end

  defp status_by_url(_statuses), do: %{}

  defp maybe_put_error(result, %{"status" => status}) when status not in ["success", "ok", 200],
    do: Map.put(result, "error", to_string(status))

  defp maybe_put_error(result, _status), do: result

  defp maybe_put_position(result, %{"position" => position}) when is_integer(position),
    do: Map.put(result, "position", position)

  defp maybe_put_position(result, _item), do: result

  defp string_value(map, key) do
    case Map.get(map, key) || Map.get(map, String.to_existing_atom(key)) do
      value when is_binary(value) -> value
      value when is_integer(value) or is_float(value) -> to_string(value)
      _value -> ""
    end
  rescue
    ArgumentError -> Map.get(map, key) || ""
  end
end
