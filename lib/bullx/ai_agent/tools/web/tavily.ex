defmodule BullX.AIAgent.Tools.Web.Tavily do
  @moduledoc """
  Tavily adapter for BullX AIAgent web search and extraction tools.

  Tavily-specific request options stay here; callers receive the same normalized
  result shape as other web adapters.
  """

  alias BullX.AIAgent.Tools.Web

  @search_url "https://api.tavily.com/search"
  @extract_url "https://api.tavily.com/extract"

  def available?(_kind), do: not is_nil(Web.api_key(:tavily))

  def search(%{query: query, limit: limit}, runtime_seed) do
    body = %{
      "query" => query,
      "max_results" => min(limit, 20),
      "search_depth" => "basic",
      "include_answer" => false,
      "include_raw_content" => false,
      "include_images" => false
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
    body = %{
      "urls" => urls,
      "extract_depth" => "basic",
      "format" => "markdown",
      "include_images" => false,
      "include_favicon" => false
    }

    [url: @extract_url, json: body, headers: auth_headers(), retry: false]
    |> Keyword.merge(Web.req_options(runtime_seed))
    |> Req.post()
    |> Web.http_result()
    |> case do
      {:ok, response} -> {:ok, %{"success" => true, "results" => extract_results(response)}}
      {:error, error} -> {:error, error}
    end
  end

  defp auth_headers, do: [{"authorization", "Bearer #{Web.api_key(:tavily)}"}]

  defp search_results(%{"results" => results}, limit) when is_list(results) do
    results
    |> Enum.take(limit)
    |> Enum.map(fn item ->
      %{
        "title" => string_value(item, "title"),
        "url" => string_value(item, "url"),
        "snippet" => string_value(item, "content")
      }
    end)
  end

  defp search_results(_response, _limit), do: []

  defp extract_results(response) when is_map(response) do
    successes =
      response
      |> Map.get("results", [])
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn item ->
        %{
          "url" => string_value(item, "url"),
          "text" => string_value(item, "raw_content"),
          "title" => string_value(item, "title")
        }
      end)

    failures =
      response
      |> Map.get("failed_results", [])
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn item ->
        %{
          "url" => string_value(item, "url"),
          "text" => "",
          "error" => string_value(item, "error")
        }
      end)

    successes ++ failures
  end

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
