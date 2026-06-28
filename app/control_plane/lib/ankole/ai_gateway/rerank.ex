defmodule Ankole.AIGateway.Rerank do
  @moduledoc """
  Normalizes provider rerank bodies into the public AIGateway shape.

  Rerank providers disagree on whether result documents are echoed and whether
  the score field is named `score` or `relevance_score`. The gateway exposes one
  contract so callers can rely on `document`, `index`, and `relevance_score`.
  """

  import Ankole.AIGateway.MapUtils,
    only: [integer_value: 1, normalize_request_keys: 1, normalize_usage_map: 1]

  @doc """
  Normalizes one upstream rerank response.
  """
  @spec normalize_body(map(), map(), map()) :: {:ok, map()} | {:error, term()}
  def normalize_body(_runtime, _request, %{
        status: status,
        body: %{"error" => error} = body
      })
      when not is_nil(error),
      do:
        {:error,
         {:upstream_response_failed, upstream_body_error_status(status, error),
          normalize_request_keys(body)}}

  def normalize_body(runtime, request, %{status: status, body: body})
      when status in 200..299 and is_map(body) do
    documents =
      request
      |> normalize_request_keys()
      |> Map.get("documents", [])

    {:ok,
     body
     |> normalize_request_keys()
     |> Map.put_new("id", "gen-rerank-#{Ecto.UUID.generate()}")
     |> Map.put_new("model", runtime["model"])
     |> Map.update("results", [], &normalize_rerank_results(&1, documents))
     |> Map.update("usage", %{}, &normalize_usage_map/1)}
  end

  def normalize_body(_runtime, _request, %{status: status, body: body})
      when is_integer(status) and is_map(body),
      do: {:error, {:upstream_response_failed, status, normalize_request_keys(body)}}

  def normalize_body(_runtime, _request, response),
    do: {:error, {:invalid_upstream_response, response}}

  # Reconstructs missing result documents from the original request by index.
  # This matters for providers such as Jina when `return_documents` is false.
  defp normalize_rerank_results(results, documents) when is_list(results) do
    results
    |> Enum.with_index()
    |> Enum.map(fn
      {result, fallback_index} when is_map(result) ->
        result = normalize_request_keys(result)
        index = integer_value(Map.get(result, "index")) || fallback_index
        document = rerank_result_document(result) |> fallback_rerank_document(documents, index)
        score = Map.get(result, "relevance_score") || Map.get(result, "score") || 0.0

        result
        |> Map.drop(["text", "image", "score"])
        |> Map.put("document", normalize_rerank_document(document))
        |> Map.put("index", index)
        |> Map.put_new("relevance_score", score)

      {value, fallback_index} ->
        %{
          "document" =>
            documents
            |> Enum.at(fallback_index)
            |> case do
              nil -> %{"text" => inspect(value)}
              document -> normalize_rerank_document(document)
            end,
          "index" => fallback_index,
          "relevance_score" => 0.0
        }
    end)
  end

  defp normalize_rerank_results(_results, _documents), do: []

  defp upstream_body_error_status(_status, %{"code" => code})
       when is_integer(code) and code in 400..599,
       do: code

  defp upstream_body_error_status(status, _error)
       when is_integer(status) and status in 400..599,
       do: status

  defp upstream_body_error_status(_status, _error), do: 502

  defp rerank_result_document(%{"document" => document}), do: document

  defp rerank_result_document(result) when is_map(result) do
    result
    |> Map.take(["text", "image"])
    |> case do
      document when map_size(document) > 0 -> document
      _empty -> %{}
    end
  end

  defp fallback_rerank_document(document, documents, index) when document in [nil, %{}] do
    Enum.at(documents, index) || document || %{}
  end

  defp fallback_rerank_document(document, _documents, _index), do: document

  defp normalize_rerank_document(document) when is_binary(document), do: %{"text" => document}

  defp normalize_rerank_document(document) when is_map(document),
    do: normalize_request_keys(document)

  defp normalize_rerank_document(document), do: %{"text" => inspect(document)}
end
