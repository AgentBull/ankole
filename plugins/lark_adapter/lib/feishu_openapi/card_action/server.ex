if Code.ensure_loaded?(Plug) do
  defmodule FeishuOpenAPI.CardAction.Server do
    @moduledoc """
    Optional `Plug` adapter for interactive-card callbacks.

        plug FeishuOpenAPI.CardAction.Server, handler: MyApp.Feishu.card_handler()

    The `:handler` option is either a `%FeishuOpenAPI.CardAction.Handler{}` struct
    or a zero-arity function returning one.

    Handler return conventions:

      * a plain `map()` — encoded as the JSON response body (HTTP 200)
      * `%{body: map(), status: integer()}` — custom status code + body
      * anything else (including `nil` / `:ok`) — a `{"msg":"success"}` ack
    """

    @behaviour Plug

    alias FeishuOpenAPI.CardAction.Handler

    @impl Plug
    def init(opts) do
      [handler: Keyword.fetch!(opts, :handler)]
    end

    @impl Plug
    def call(conn, opts) do
      handler = resolve(opts[:handler])

      case read_all_body(conn) do
        {:ok, conn, body} ->
          headers = Map.new(conn.req_headers)

          handler
          |> Handler.dispatch({:raw, body, headers})
          |> reply(conn)

        {:error, conn, reason} ->
          reply({:error, reason}, conn)
      end
    end

    defp reply({:challenge, challenge}, conn) do
      respond(conn, 200, %{"challenge" => challenge})
    end

    defp reply({:ok, %{body: body, status: status}}, conn) when is_integer(status),
      do: respond(conn, status, body)

    defp reply({:ok, result}, conn) when is_map(result), do: respond(conn, 200, result)

    defp reply({:ok, _}, conn), do: respond(conn, 200, %{"msg" => "success"})

    defp reply({:error, reason}, conn) do
      respond(conn, 400, %{"msg" => "invalid card callback: #{inspect(reason)}"})
    end

    defp respond(conn, status, body) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Torque.encode!(body))
      |> Plug.Conn.halt()
    end

    defp resolve(fun) when is_function(fun, 0), do: fun.()
    defp resolve(%Handler{} = handler), do: handler

    # Read the full body here (not via a parser) because card-action signature
    # verification hashes the exact raw bytes. Chunks are prepended then reversed;
    # the 8 MB read length bounds buffering.
    defp read_all_body(conn, acc \\ []) do
      case Plug.Conn.read_body(conn, length: 8_000_000) do
        {:ok, body, conn} ->
          {:ok, conn, IO.iodata_to_binary(Enum.reverse([body | acc]))}

        {:more, body, conn} ->
          read_all_body(conn, [body | acc])

        {:error, reason} ->
          {:error, conn, reason}
      end
    end
  end
end
