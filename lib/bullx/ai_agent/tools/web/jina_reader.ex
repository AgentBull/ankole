defmodule BullX.AIAgent.Tools.Web.JinaReader do
  @moduledoc """
  Jina Reader adapter for BullX AIAgent web extraction.

  Jina can run without a configured API key, so this adapter is always available
  for extraction and normalizes provider failures into per-URL result errors.
  """

  alias BullX.AIAgent.Tools.Web

  @reader_url "https://r.jina.ai/"

  def available?(:extract), do: true
  def available?(_kind), do: false

  def extract(%{urls: urls}, runtime_seed) do
    results = Enum.map(urls, &extract_one(&1, runtime_seed))

    {:ok,
     %{
       "success" => true,
       "results" => results
     }}
  end

  defp extract_one(url, runtime_seed) do
    [url: @reader_url, json: %{"url" => url}, headers: headers(), retry: false]
    |> Keyword.merge(Web.req_options(runtime_seed))
    |> Req.post()
    |> Web.http_result()
    |> case do
      {:ok, response} -> extract_result(url, response)
      {:error, error} -> %{"url" => url, "text" => "", "error" => error.message}
    end
  end

  defp headers do
    base = [{"accept", "application/json"}, {"x-respond-with", "content"}]

    case Web.api_key(:jina_reader) do
      nil -> base
      key -> [{"authorization", "Bearer #{key}"} | base]
    end
  end

  defp extract_result(original_url, %{"data" => data}) when is_map(data) do
    %{
      "url" => string_value(data, "url", original_url),
      "title" => string_value(data, "title", ""),
      "text" => text_value(data)
    }
  end

  defp extract_result(original_url, response) when is_map(response) do
    %{
      "url" => string_value(response, "url", original_url),
      "title" => string_value(response, "title", ""),
      "text" => text_value(response)
    }
  end

  defp text_value(data) do
    string_value(data, "content", string_value(data, "text", ""))
  end

  defp string_value(map, key, default) do
    case Map.get(map, key) || Map.get(map, String.to_existing_atom(key)) do
      value when is_binary(value) -> value
      value when is_integer(value) or is_float(value) -> to_string(value)
      _value -> default
    end
  rescue
    ArgumentError -> Map.get(map, key) || default
  end
end
