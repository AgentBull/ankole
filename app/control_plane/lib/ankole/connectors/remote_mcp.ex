defmodule Ankole.Connectors.RemoteMCP do
  @moduledoc "Streamable HTTP upstream transport shared by Connector toolkits and Skill proxies."
  use GenServer
  alias Ankole.Files.HTTP
  @version "2026-07-28"
  @legacy "2025-11-25"

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  @impl true
  def init(_) do
    :ets.new(__MODULE__, [:named_table, :public, :set, read_concurrency: true])
    Process.send_after(self(), :expire, 60_000)
    {:ok, nil}
  end

  @impl true
  def handle_info(:expire, state) do
    now = System.monotonic_time(:millisecond)

    for {key, connection, expires} <- :ets.tab2list(__MODULE__), expires < now do
      :ets.delete(__MODULE__, key)

      if connection.session do
        tenant = elem(key, 0)

        Task.start(fn ->
          Ankole.Repo.with_tenant(tenant, fn -> close_connection(connection) end)
        end)
      end
    end

    Process.send_after(self(), :expire, 60_000)
    {:noreply, state}
  end

  def call(url, headers, name, args, opts \\ []) do
    with {:ok, connection} <- cached(url, headers, opts),
         {:ok, result, connection} <-
           request(connection, "tools/call", %{"name" => name, "arguments" => args}, opts) do
      remember(url, headers, opts, connection)

      {:ok, result}
    end
  end

  def list_tools(url, headers, opts \\ []) do
    with {:ok, connection} <- cached(url, headers, opts),
         {:ok, tools, connection} <- catalog(connection, opts) do
      remember(url, headers, opts, connection)
      {:ok, tools}
    end
  end

  defp catalog(%{tools: tools, tools_expires_at: expires} = connection, opts) do
    if expires > System.monotonic_time(:millisecond),
      do: {:ok, tools, connection},
      else: catalog(Map.drop(connection, [:tools, :tools_expires_at]), opts)
  end

  defp catalog(connection, opts) do
    with {:ok, result, connection} <- discover(connection, opts),
         {:ok, tools, connection} <- more_tools(connection, result, opts) do
      {:ok, tools,
       Map.merge(connection, %{
         tools: tools,
         tools_expires_at: System.monotonic_time(:millisecond) + 600_000
       })}
    end
  end

  def close(url, headers, opts \\ []) do
    key = key(url, headers, opts)

    case :ets.take(__MODULE__, key) do
      [{_, connection, _}] -> close_connection(connection)
      [] -> :ok
    end
  end

  defp discover(%{first_tools: result} = connection, _opts),
    do: {:ok, result, Map.delete(connection, :first_tools)}

  defp discover(connection, opts),
    do: request(connection, "tools/list", %{}, Keyword.put(opts, :idempotent, true))

  defp more_tools(connection, result, opts) do
    if cursor = result["nextCursor"] do
      with {:ok, next, connection} <-
             request(
               connection,
               "tools/list",
               %{"cursor" => cursor},
               Keyword.put(opts, :idempotent, true)
             ),
           {:ok, tools, connection} <- more_tools(connection, next, opts),
           do: {:ok, (result["tools"] || []) ++ tools, connection}
    else
      {:ok, result["tools"] || [], connection}
    end
  end

  defp request(connection, method, params, opts) do
    safe = Keyword.get(opts, :idempotent, false)

    case rpc(connection, method, params, safe) do
      {:error, {:mcp_protocol, 404, _}} when not is_nil(connection.session) ->
        with {:ok, renewed} <- initialize(%{connection | session: nil}),
             do: rpc(renewed, method, params, safe)

      result ->
        result
    end
  end

  defp cached(url, headers, opts) do
    deadline = Keyword.get(opts, :deadline, System.monotonic_time(:millisecond) + 60_000)

    case :ets.lookup(__MODULE__, key(url, headers, opts)) do
      [{_, connection, _}] ->
        {:ok, %{connection | headers: headers, deadline: deadline}}

      [] ->
        connection(
          %{
            "transport" => "streamable_http",
            "url" => url,
            "headers" => headers,
            "protocol_version" => Keyword.get(opts, :protocol_version)
          },
          %{"deadline" => deadline}
        )
    end
  end

  defp key(url, headers, opts),
    do:
      {Ankole.Repo.tenant_id!(), Keyword.get(opts, :cache_key), url,
       :crypto.hash(:sha256, :erlang.term_to_binary(headers))}

  defp remember(url, headers, opts, connection),
    do:
      :ets.insert(
        __MODULE__,
        {key(url, headers, opts), Map.delete(connection, :first_tools),
         System.monotonic_time(:millisecond) + 600_000}
      )

  defp close_connection(%{session: nil}), do: :ok

  defp close_connection(connection) do
    HTTP.request(
      "DELETE",
      connection.url,
      [
        {"mcp-session-id", connection.session},
        {"mcp-protocol-version", connection.version} | connection.headers
      ],
      nil,
      timeout: 5_000,
      idempotent: true
    )
  end

  defp connection(%{"transport" => "streamable_http"} = server, context) do
    connection = %{
      url: server["url"],
      headers: server["headers"] || [],
      version: @version,
      deadline: context["deadline"] || System.monotonic_time(:millisecond) + 60_000,
      session: nil
    }

    if server["protocol_version"] == "legacy" do
      initialize(connection)
    else
      case rpc(connection, "tools/list", %{}, true) do
        {:ok, result, connection} ->
          {:ok, Map.put(connection, :first_tools, result)}

        {:error, {:mcp_protocol, status, error}}
        when status in [400, 404, 405, 406] or error in [-32600, -32601, -32000] ->
          initialize(connection)

        error ->
          error
      end
    end
  end

  defp connection(_, _), do: {:error, :applet_mcp_requires_http_transport}

  defp initialize(connection) do
    connection = %{connection | version: @legacy}

    with {:ok, result, connection} <-
           rpc(
             connection,
             "initialize",
             %{
               "protocolVersion" => @legacy,
               "capabilities" => %{},
               "clientInfo" => %{"name" => "Ankole", "version" => "2"}
             },
             true
           ),
         connection = %{connection | version: result["protocolVersion"]},
         {:ok, _, connection} <- rpc(connection, "notifications/initialized", %{}, true) do
      {:ok, connection}
    end
  end

  defp rpc(connection, method, params, idempotent?) do
    id = Ash.UUIDv7.generate()
    notification? = String.starts_with?(method, "notifications/")

    params =
      if connection.version == @version,
        do:
          Map.put(params, "_meta", %{
            "io.modelcontextprotocol/protocolVersion" => @version,
            "io.modelcontextprotocol/clientInfo" => %{"name" => "Ankole", "version" => "2"},
            "io.modelcontextprotocol/clientCapabilities" => %{}
          }),
        else: params

    body =
      %{"jsonrpc" => "2.0", "method" => method, "params" => params}
      |> then(fn body -> if notification?, do: body, else: Map.put(body, "id", id) end)
      |> Torque.encode!()

    headers =
      [
        {"content-type", "application/json"},
        {"accept", "application/json, text/event-stream"},
        {"mcp-protocol-version", connection.version},
        {"mcp-method", method}
      ] ++ connection.headers

    headers = if params["name"], do: [{"mcp-name", params["name"]} | headers], else: headers

    headers =
      if connection.session, do: [{"mcp-session-id", connection.session} | headers], else: headers

    timeout = connection.deadline - System.monotonic_time(:millisecond)

    cond do
      byte_size(body) > 5_000_000 ->
        {:error, :json_too_large}

      timeout <= 0 ->
        {:error, :handler_timeout}

      true ->
        with {:ok, response} <-
               HTTP.request("POST", connection.url, headers, body,
                 timeout: timeout,
                 idempotent: idempotent?
               ),
             {:ok, decoded} <- decode_response(response, id, notification?, idempotent?),
             decoded = Ankole.Connectors.HTTP.redact_credentials(decoded, connection.headers) do
          session =
            Enum.find_value(response.headers, connection.session, fn {key, value} ->
              if key == "mcp-session-id", do: value
            end)

          cond do
            get_in(decoded, ["error", "code"]) == -32603 and not idempotent? ->
              {:error,
               %{code: "upstream_outcome_unknown", retryable: false, upstream_code: -32603}}

            response.status >= 400 or decoded["error"] ->
              {:error, {:mcp_protocol, response.status, get_in(decoded, ["error", "code"])}}

            true ->
              {:ok, decoded["result"] || %{}, %{connection | session: session}}
          end
        else
          {:error, error} when is_map(error) ->
            {:error, Ankole.Connectors.HTTP.redact_credentials(error, connection.headers)}

          error ->
            error
        end
    end
  end

  defp decode_response(%{status: status} = response, _id, _notification?, idempotent?)
       when status == 429 or status >= 500,
       do: Ankole.Connectors.HTTP.decode(response, idempotent: idempotent?)

  defp decode_response(%{status: status, body: body}, _id, _notification?, _idempotent?)
       when status >= 400 do
    code =
      case Torque.decode(body) do
        {:ok, value} -> get_in(value, ["error", "code"])
        _ -> nil
      end

    {:error, {:mcp_protocol, status, code}}
  end

  defp decode_response(response, id, notification?, _idempotent?),
    do: decode(response.body, id, notification?)

  defp decode("", _id, true), do: {:ok, %{}}

  defp decode(bytes, id, _) do
    if String.valid?(bytes) do
      case Torque.decode(bytes) do
        {:ok, %{"id" => ^id} = value} ->
          {:ok, value}

        _ ->
          bytes
          |> String.split(~r/\r?\n\r?\n/)
          |> Enum.find_value(fn event ->
            payload =
              event
              |> String.split(~r/\r?\n/)
              |> Enum.filter(&String.starts_with?(&1, "data:"))
              |> Enum.map_join("\n", &String.trim_leading(String.replace_prefix(&1, "data:", "")))

            case Torque.decode(payload) do
              {:ok, %{"id" => ^id} = result} -> {:ok, result}
              _ -> nil
            end
          end) || {:error, :invalid_mcp_response}
      end
    else
      {:error, :invalid_utf8}
    end
  end
end
