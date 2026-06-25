if Code.ensure_loaded?(Plug) do
  defmodule FeishuOpenAPI.Event.Server do
    @moduledoc """
    Optional `Plug` that reads a Feishu/Lark webhook POST, hands the body to a
    `FeishuOpenAPI.Event.Dispatcher`, and serializes the handler result as JSON.

        plug FeishuOpenAPI.Event.Server, dispatcher: MyApp.Feishu.dispatcher()

    The `:dispatcher` option is either a `%FeishuOpenAPI.Event.Dispatcher{}` struct
    or a zero-arity function returning one (for runtime resolution).

    Handler return conventions:
      * A plain `map()` — encoded as the JSON response body (HTTP 200).
      * `%{body: map(), status: integer()}` — custom status code + body.
      * Anything else (including `nil` / `:ok`) — a `{"msg":"success"}` ack.

    A URL-verification challenge (`{"type":"url_verification"}`) is echoed
    back automatically.
    """

    @behaviour Plug

    alias FeishuOpenAPI.Event.Dispatcher

    @impl Plug
    def init(opts) do
      [dispatcher: Keyword.fetch!(opts, :dispatcher)]
    end

    @impl Plug
    def call(conn, opts) do
      dispatcher = resolve(opts[:dispatcher])

      case read_all_body(conn) do
        {:ok, conn, body} ->
          headers = Map.new(conn.req_headers)

          dispatcher
          |> Dispatcher.dispatch({:raw, body, headers})
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

    # Handler reached but failed/crashed → 5xx so Feishu retries delivery, and the
    # reason is kept off the wire to avoid leaking internals.
    defp reply({:error, {:handler_failed, _reason}}, conn) do
      respond(conn, 500, %{"msg" => "handler failed"})
    end

    defp reply({:error, {:handler_crashed, _reason}}, conn) do
      respond(conn, 500, %{"msg" => "handler failed"})
    end

    # Verification/decode failures are client-side (bad signature, malformed body)
    # → 400; retrying won't help, so we don't ask Feishu to.
    defp reply({:error, reason}, conn) do
      respond(conn, 400, %{"msg" => "invalid webhook: #{inspect(reason)}"})
    end

    defp respond(conn, status, body) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Torque.encode!(body))
      |> Plug.Conn.halt()
    end

    defp resolve(fun) when is_function(fun, 0), do: fun.()
    defp resolve(%Dispatcher{} = d), do: d

    # Read the whole body ourselves (chunks prepended for O(1), reversed at the
    # end) rather than trusting an upstream parser: signature verification needs
    # the exact raw bytes, byte-for-byte. The 8 MB read length bounds buffering.
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
