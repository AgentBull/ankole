defmodule SlackOpenAPI.Pagination do
  @moduledoc "Lazy cursor pagination for Slack Web API list methods."

  alias SlackOpenAPI.{Client, Error}

  @max_rate_limit_retries 3

  @spec stream(Client.t(), String.t(), keyword()) :: Enumerable.t()
  def stream(%Client{} = client, method, opts \\ []) do
    items_path = Keyword.get(opts, :items, ["items"])
    forwarded = Keyword.drop(opts, [:items])

    Stream.resource(
      fn -> {:page, nil, 0} end,
      fn
        :done ->
          {:halt, :done}

        {:page, cursor, retries} ->
          query = put_cursor(Keyword.get(forwarded, :query, []), cursor)

          case SlackOpenAPI.get(client, method, Keyword.put(forwarded, :query, query)) do
            {:ok, body} ->
              items = get_in_path(body, items_path) || []
              next_cursor = get_in_path(body, ["response_metadata", "next_cursor"])

              next =
                if is_binary(next_cursor) and next_cursor != "",
                  do: {:page, next_cursor, 0},
                  else: :done

              {Enum.map(items, &{:ok, &1}), next}

            {:error, %Error{reason: :rate_limited, retry_after: seconds}}
            when retries < @max_rate_limit_retries ->
              Process.sleep(:timer.seconds(max(seconds || 1, 1)))
              {[], {:page, cursor, retries + 1}}

            {:error, %Error{} = error} ->
              {[{:error, error}], :done}
          end
      end,
      fn _state -> :ok end
    )
  end

  defp put_cursor(query, nil), do: query
  defp put_cursor(query, cursor) when is_list(query), do: Keyword.put(query, :cursor, cursor)
  defp put_cursor(query, cursor) when is_map(query), do: Map.put(query, :cursor, cursor)

  defp get_in_path(value, []), do: value

  defp get_in_path(map, [key | rest]) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> get_in_path(value, rest)
      :error -> nil
    end
  end

  defp get_in_path(_value, _path), do: nil
end
