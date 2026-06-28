defmodule Ankole.AIGateway.Embeddings do
  @moduledoc """
  Normalizes provider embedding bodies into the public AIGateway shape.

  OpenRouter and Jina are close to the OpenAI embedding response shape, but they
  may omit item indexes or report provider errors in a 2xx body. This module
  keeps the downstream body stable and turns those error bodies into failures.
  """

  import Ankole.AIGateway.MapUtils, only: [normalize_request_keys: 1, normalize_usage_map: 1]

  @doc """
  Normalizes one upstream embedding response.
  """
  @spec normalize_body(map(), map()) :: {:ok, map()} | {:error, term()}
  def normalize_body(_runtime, %{status: status, body: %{"error" => error} = body})
      when not is_nil(error),
      do:
        {:error,
         {:upstream_response_failed, upstream_body_error_status(status, error),
          normalize_request_keys(body)}}

  def normalize_body(runtime, %{status: status, body: body})
      when status in 200..299 and is_map(body) do
    {:ok,
     body
     |> normalize_request_keys()
     |> Map.put_new("model", runtime["model"])
     |> Map.update("data", [], &normalize_embedding_data/1)
     |> Map.update("usage", %{}, &normalize_usage_map/1)}
  end

  def normalize_body(_runtime, %{status: status, body: body})
      when is_integer(status) and is_map(body),
      do: {:error, {:upstream_response_failed, status, normalize_request_keys(body)}}

  def normalize_body(_runtime, response),
    do: {:error, {:invalid_upstream_response, response}}

  # Some providers return a bare embedding array while others return objects.
  # The worker contract always sees objects with `embedding` and `index`.
  defp normalize_embedding_data(data) when is_list(data) do
    data
    |> Enum.with_index()
    |> Enum.map(fn
      {item, fallback_index} when is_map(item) ->
        item
        |> normalize_request_keys()
        |> case do
          %{"embedding" => _embedding} = item -> Map.put_new(item, "index", fallback_index)
          item -> %{"embedding" => item, "index" => fallback_index}
        end

      {embedding, fallback_index} when is_list(embedding) ->
        %{"embedding" => embedding, "index" => fallback_index}

      {item, fallback_index} ->
        %{"embedding" => item, "index" => fallback_index}
    end)
  end

  defp normalize_embedding_data(_data), do: []

  defp upstream_body_error_status(_status, %{"code" => code})
       when is_integer(code) and code in 400..599,
       do: code

  defp upstream_body_error_status(status, _error)
       when is_integer(status) and status in 400..599,
       do: status

  defp upstream_body_error_status(_status, _error), do: 502
end
