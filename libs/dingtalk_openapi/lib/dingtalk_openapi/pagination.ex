defmodule DingTalkOpenAPI.Pagination do
  @moduledoc """
  Lazy cursor pagination for DingTalk old-domain (`topapi/*`) list endpoints.

  These endpoints return `{"errcode" => 0, "result" => {"has_more" => bool,
  "next_cursor" => n, "list" => [...]}}` and take a `cursor` (plus `size`) in the
  request body. This wraps that loop as a `Stream.resource/3` yielding
  `{:ok, item}` per item and a single terminal `{:error, %Error{}}` on failure.
  """

  alias DingTalkOpenAPI.{Client, Error}

  @default_items_path ["result", "list"]
  @default_has_more_path ["result", "has_more"]
  @default_next_cursor_path ["result", "next_cursor"]

  @doc """
  Stream items across all pages of `path` (a `POST` old-domain list endpoint).

  Options:

    * `:body` — base request body merged with the `cursor`/`size` each page.
    * `:size` — page size (default 100).
    * `:items` / `:has_more` / `:next_cursor` — response path overrides.
  """
  @spec stream(Client.t(), String.t(), keyword()) :: Enumerable.t()
  def stream(%Client{} = client, path, opts \\ []) do
    items_path = Keyword.get(opts, :items, @default_items_path)
    has_more_path = Keyword.get(opts, :has_more, @default_has_more_path)
    next_cursor_path = Keyword.get(opts, :next_cursor, @default_next_cursor_path)
    size = Keyword.get(opts, :size, 100)
    base_body = Keyword.get(opts, :body, %{}) |> normalize_body()

    Stream.resource(
      fn -> {:page, 0} end,
      fn
        :done ->
          {:halt, :done}

        {:page, cursor} ->
          body = Map.merge(base_body, %{"cursor" => cursor, "size" => size})

          case DingTalkOpenAPI.post(client, path, body: body) do
            {:ok, response} when is_map(response) ->
              items = get_in_path(response, items_path) || []
              has_more = get_in_path(response, has_more_path)
              next_cursor = get_in_path(response, next_cursor_path)

              next =
                if has_more && is_integer(next_cursor),
                  do: {:page, next_cursor},
                  else: :done

              {Enum.map(items, &{:ok, &1}), next}

            {:error, %Error{} = error} ->
              {[{:error, error}], :done}
          end
      end,
      fn _state -> :ok end
    )
  end

  defp normalize_body(body) when is_map(body), do: body
  defp normalize_body(body) when is_list(body), do: Map.new(body)

  defp get_in_path(value, []), do: value

  defp get_in_path(map, [key | rest]) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> get_in_path(value, rest)
      :error -> nil
    end
  end

  defp get_in_path(_value, _path), do: nil
end
