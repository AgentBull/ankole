defmodule FeishuOpenAPI.Pagination do
  @moduledoc """
  Lazy `Stream` helpers for paginated Feishu/Lark list endpoints.

  Feishu list endpoints mostly use a `page_token` / `has_more` convention
  inside the `data` field. Some generated SDK endpoints also expose
  `next_page_token`; this module follows the official SDK behavior by using
  `page_token` first and falling back to `next_page_token`. It wraps that
  pagination loop as a
  `Stream.resource/3`, so callers can enumerate items lazily, `Enum.take/2`
  them, or pipe into further `Stream` operations without materializing the
  whole list.

  ## Two entry points

    * `stream/3` — yields `{:ok, item}` per item and emits a single terminal
      `{:error, %FeishuOpenAPI.Error{}}` if a page fetch fails. This variant is
      explicit about failure so early-terminating operators like `Enum.take/2`
      cannot silently hide an error.
    * `stream!/3` — yields bare items and raises `FeishuOpenAPI.Error` on a
      failed page fetch. Use this when you just want items and are happy to
      unwind on failure.

  ## Basic usage

      client = FeishuOpenAPI.new(app_id, app_secret)

      FeishuOpenAPI.Pagination.stream!(client, "contact/v3/users",
        query: [department_id: "od_xxx", page_size: 50])
      |> Stream.take(200)
      |> Enum.to_list()

  Or with explicit error handling:

      FeishuOpenAPI.Pagination.stream(client, "contact/v3/users")
      |> Enum.reduce_while([], fn
        {:ok, item}, acc -> {:cont, [item | acc]}
        {:error, %FeishuOpenAPI.Error{} = err}, _acc -> {:halt, {:error, err}}
      end)

  `:query` and all other `opts` are forwarded to `FeishuOpenAPI.get/3`; the
  stream appends the page cursor parameter automatically.

  ## Custom response shapes

  Some endpoints nest items under a different key or use a different cursor
  field name. Override via:

    * `:items` — list of path segments to the items array. Default
      `["data", "items"]`.
    * `:has_more` — path to the `has_more` boolean. Default
      `["data", "has_more"]`.
    * `:page_token` — primary path to the next-page token. Default
      `["data", "page_token"]`.
    * `:next_page_token` — fallback path to the next-page token. Default
      `["data", "next_page_token"]`.
    * `:page_token_param` — query-param name sent back to the API. Default
      `:page_token`.
  """

  alias FeishuOpenAPI.{Client, Error}

  @type opts :: [
          query: keyword() | map(),
          items: [String.t()],
          has_more: [String.t()],
          page_token: [String.t()],
          next_page_token: [String.t()],
          page_token_param: atom()
        ]

  @default_items_path ["data", "items"]
  @default_has_more_path ["data", "has_more"]
  @default_page_token_path ["data", "page_token"]
  @default_next_page_token_path ["data", "next_page_token"]
  @default_page_token_param :page_token

  @doc """
  Returns a `Stream` of `{:ok, item}` tuples across all pages of `path`.

  On a failed page fetch, the stream emits a single terminal
  `{:error, %FeishuOpenAPI.Error{}}` element and halts. Callers must pattern-match
  both shapes — early-terminating consumers like `Enum.take/2` would otherwise
  silently drop the error.

  See the module docs for alternatives (`stream!/3`) and `:items` / `:has_more` /
  `:page_token` / `:next_page_token` / `:page_token_param` overrides.
  """
  @spec stream(Client.t(), String.t(), keyword()) :: Enumerable.t()
  def stream(%Client{} = client, path, opts \\ []) do
    items_path = Keyword.get(opts, :items, @default_items_path)
    has_more_path = Keyword.get(opts, :has_more, @default_has_more_path)
    page_token_path = Keyword.get(opts, :page_token, @default_page_token_path)
    next_page_token_path = Keyword.get(opts, :next_page_token, @default_next_page_token_path)
    page_token_param = Keyword.get(opts, :page_token_param, @default_page_token_param)

    forwarded =
      Keyword.drop(opts, [:items, :has_more, :page_token, :next_page_token, :page_token_param])

    Stream.resource(
      fn -> :first_page end,
      fn
        :done ->
          {:halt, :done}

        page_token ->
          query =
            forwarded
            |> Keyword.get(:query, [])
            |> put_page_token(page_token, page_token_param)

          case FeishuOpenAPI.get(client, path, Keyword.put(forwarded, :query, query)) do
            {:ok, body} when is_map(body) ->
              items = get_in_path(body, items_path) || []
              wrapped = Enum.map(items, &{:ok, &1})
              has_more = get_in_path(body, has_more_path)
              next_token = page_token(body, page_token_path, next_page_token_path)

              cond do
                has_more && is_binary(next_token) ->
                  {wrapped, next_token}

                true ->
                  {wrapped, :done}
              end

            {:error, %Error{} = err} ->
              {[{:error, err}], :done}
          end
      end,
      fn _ -> :ok end
    )
  end

  @doc """
  Like `stream/3`, but yields bare items and raises `FeishuOpenAPI.Error` if a
  page fetch fails.

  Use this when you want simple iteration and are fine with the error unwinding
  the caller (e.g. in a script, test, or a context that already wraps API
  calls in a `try`/`rescue`).
  """
  @spec stream!(Client.t(), String.t(), keyword()) :: Enumerable.t()
  def stream!(%Client{} = client, path, opts \\ []) do
    client
    |> stream(path, opts)
    |> Stream.map(fn
      {:ok, item} -> item
      {:error, %Error{} = err} -> raise err
    end)
  end

  defp put_page_token(query, :first_page, _param) when is_list(query), do: query
  defp put_page_token(query, :first_page, _param) when is_map(query), do: Enum.to_list(query)

  defp put_page_token(query, token, param) when is_list(query) do
    Keyword.put(query, param, token)
  end

  defp put_page_token(query, token, param) when is_map(query) do
    query |> Map.put(param, token) |> Enum.to_list()
  end

  defp page_token(body, page_token_path, next_page_token_path) do
    [page_token_path, next_page_token_path]
    |> Enum.find_value(fn path ->
      case get_in_path(body, path) do
        token when is_binary(token) and token != "" -> token
        _other -> nil
      end
    end)
  end

  defp get_in_path(nil, _path), do: nil
  defp get_in_path(map, []), do: map

  defp get_in_path(map, [key | rest]) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> get_in_path(value, rest)
      :error -> nil
    end
  end

  defp get_in_path(_other, _path), do: nil
end
