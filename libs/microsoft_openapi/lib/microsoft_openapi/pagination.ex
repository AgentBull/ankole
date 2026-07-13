defmodule MicrosoftOpenAPI.Pagination do
  @moduledoc "Lazy `@odata.nextLink` pagination for Microsoft Graph collections."

  alias MicrosoftOpenAPI.Client
  alias MicrosoftOpenAPI.Error
  alias MicrosoftOpenAPI.Graph

  @max_rate_limit_retries 3

  @spec stream(Client.t(), String.t(), keyword()) :: Enumerable.t()
  def stream(%Client{} = client, path, opts \\ []) do
    Stream.resource(
      fn -> {:page, path, opts, 0} end,
      fn
        :done ->
          {:halt, :done}

        {:page, url, page_opts, retries} ->
          case Graph.get(client, url, page_opts) do
            {:ok, body} ->
              items = Map.get(body, "value") || []

              next =
                case Map.get(body, "@odata.nextLink") do
                  # nextLink already encodes the query; forwarding the first
                  # page's query params would duplicate them.
                  next_link when is_binary(next_link) and next_link != "" ->
                    {:page, next_link, Keyword.delete(page_opts, :query), 0}

                  _absent ->
                    :done
                end

              {Enum.map(items, &{:ok, &1}), next}

            {:error, %Error{reason: :rate_limited, retry_after: seconds}}
            when retries < @max_rate_limit_retries ->
              Process.sleep(:timer.seconds(max(seconds || 1, 1)))
              {[], {:page, url, page_opts, retries + 1}}

            {:error, %Error{} = error} ->
              {[{:error, error}], :done}
          end
      end,
      fn _state -> :ok end
    )
  end
end
