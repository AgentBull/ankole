defmodule BullX.AIAgent.Tools.Web.SerpAPI do
  @moduledoc false

  alias BullX.AIAgent.Tools.Web

  @search_url "https://serpapi.com/search"

  def available?(:search), do: not is_nil(Web.api_key(:serpapi))
  def available?(_kind), do: false

  def search(%{query: query, limit: limit}, runtime_seed) do
    params = [
      engine: "google",
      q: query,
      output: "json",
      api_key: Web.api_key(:serpapi)
    ]

    [url: @search_url, params: params, retry: false]
    |> Keyword.merge(Web.req_options(runtime_seed))
    |> Req.get()
    |> Web.http_result()
    |> case do
      {:ok, response} ->
        {:ok,
         %{"success" => true, "query" => query, "results" => search_results(response, limit)}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp search_results(%{"organic_results" => results}, limit) when is_list(results) do
    results
    |> Enum.take(limit)
    |> Enum.map(fn item ->
      %{
        "title" => string_value(item, "title"),
        "url" => string_value(item, "link"),
        "snippet" => string_value(item, "snippet")
      }
      |> maybe_put_position(item)
    end)
  end

  defp search_results(_response, _limit), do: []

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
