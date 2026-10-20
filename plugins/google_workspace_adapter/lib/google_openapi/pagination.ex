defmodule GoogleOpenAPI.Pagination do
  @moduledoc "Lazy `nextPageToken` pagination for Google list endpoints."

  alias GoogleOpenAPI.Error

  @max_rate_limit_retries 3

  @doc """
  Streams `{:ok, item}`/`{:error, error}` tuples across pages.

  `fetch` receives the query (with `pageToken` set on follow-up pages) and
  returns one page. `items_key` names the array field in the page body.
  """
  @spec stream((keyword() -> {:ok, map()} | {:error, Error.t()}), String.t(), keyword()) ::
          Enumerable.t()
  def stream(fetch, items_key, query \\ [])
      when is_function(fetch, 1) and is_binary(items_key) do
    Stream.resource(
      fn -> {:page, nil, 0} end,
      fn
        :done ->
          {:halt, :done}

        {:page, page_token, retries} ->
          page_query =
            case page_token do
              nil -> query
              token -> Keyword.put(query, :pageToken, token)
            end

          case fetch.(page_query) do
            {:ok, body} ->
              items = Map.get(body, items_key) || []

              next =
                case Map.get(body, "nextPageToken") do
                  token when is_binary(token) and token != "" -> {:page, token, 0}
                  _absent -> :done
                end

              {Enum.map(items, &{:ok, &1}), next}

            {:error, %Error{reason: :rate_limited, retry_after: seconds}}
            when retries < @max_rate_limit_retries ->
              Process.sleep(:timer.seconds(max(seconds || 1, 1)))
              {[], {:page, page_token, retries + 1}}

            {:error, %Error{} = error} ->
              {[{:error, error}], :done}
          end
      end,
      fn _state -> :ok end
    )
  end
end
