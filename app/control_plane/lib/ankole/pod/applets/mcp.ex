defmodule Ankole.Pod.Applets.MCP do
  @moduledoc "Applet MCP calls use Skill-owned declarations and server-owned tool annotations."
  alias Ankole.Files.HTTP
  @version "2026-07-28"
  @legacy "2025-11-25"

  def call(actor, tool, args, options, context)
      when is_binary(tool) and is_map(args) and is_map(options) do
    with {:ok, principal} <-
           Ankole.Pod.Access.write(actor.turn_authority, fn ->
             Ankole.Pod.Access.principal(actor)
           end),
         {:ok, server} <-
           Ankole.AIAgent.resolve_mcp_server(principal, options["skill"], options["server"]),
         true <- allowed?(server, tool),
         cache_key = {principal.uid, server, tool},
         {:ok, definition, connection} <- tool(context, cache_key, server, tool),
         :ok <- readonly(context, definition),
         {:ok, result, connection} <-
           rpc(
             connection,
             "tools/call",
             %{"name" => tool, "arguments" => args},
             get_in(definition, ["annotations", "idempotentHint"]) == true or
               get_in(definition, ["annotations", "readOnlyHint"]) == true
           ) do
      cache_tool(context, cache_key, definition, connection)
      schema = definition["outputSchema"] || %{}
      {:ok, Map.update(result, "structuredContent", nil, &int64_strings(&1, schema, schema))}
    else
      false -> {:error, :mcp_tool_not_enabled}
      error -> error
    end
  end

  def call(_, _, _, _, _), do: {:error, :invalid_request}

  defp tool(context, key, server, name) do
    case context[:mcp_tools] && :ets.lookup(context[:mcp_tools], key) do
      [{^key, definition, connection}] ->
        {:ok, definition, connection}

      _ ->
        with {:ok, connection} <- connection(server, context),
             {:ok, definition, connection} <- find_tool(connection, name, nil) do
          cache_tool(context, key, definition, connection)
          {:ok, definition, connection}
        end
    end
  end

  defp cache_tool(context, key, definition, connection) do
    if table = context[:mcp_tools], do: :ets.insert(table, {key, definition, connection})
  end

  defp allowed?(server, tool),
    do:
      tool not in (server["disabled_tools"] || []) and
        (is_nil(server["enabled_tools"]) or tool in server["enabled_tools"])

  defp readonly(context, definition) do
    if context["read_only"] == true and
         get_in(definition, ["annotations", "readOnlyHint"]) != true,
       do: {:error, :read_only_route},
       else: :ok
  end

  defp connection(%{"transport" => "streamable_http"} = server, context) do
    connection = %{
      url: server["url"],
      headers: server["headers"],
      version: @version,
      deadline: context["deadline"],
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

  defp find_tool(%{first_tools: result} = connection, name, nil),
    do: select_tool(Map.delete(connection, :first_tools), result, name)

  defp find_tool(connection, name, cursor) do
    params = if cursor, do: %{"cursor" => cursor}, else: %{}

    with {:ok, result, connection} <- rpc(connection, "tools/list", params, true),
         do: select_tool(connection, result, name)
  end

  defp select_tool(connection, result, name) do
    case Enum.find(result["tools"] || [], &(&1["name"] == name)) do
      nil ->
        if result["nextCursor"],
          do: find_tool(connection, name, result["nextCursor"]),
          else: {:error, :mcp_tool_not_found}

      tool ->
        {:ok, tool, connection}
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
             {:ok, decoded} <- decode_response(response, id, notification?) do
          session =
            Enum.find_value(response.headers, connection.session, fn {key, value} ->
              if key == "mcp-session-id", do: value
            end)

          cond do
            response.status >= 400 or decoded["error"] ->
              {:error, {:mcp_protocol, response.status, get_in(decoded, ["error", "code"])}}

            true ->
              {:ok, decoded["result"] || %{}, %{connection | session: session}}
          end
        end
    end
  end

  defp decode_response(%{status: status, body: body}, _id, _notification?) when status >= 400 do
    code =
      case Torque.decode(body) do
        {:ok, value} -> get_in(value, ["error", "code"])
        _ -> nil
      end

    {:error, {:mcp_protocol, status, code}}
  end

  defp decode_response(response, id, notification?), do: decode(response.body, id, notification?)

  defp decode("", _id, true), do: {:ok, %{}}

  defp decode(bytes, id, _) do
    if String.valid?(bytes) do
      case Torque.decode(bytes) do
        {:ok, value} ->
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

  defp int64_strings(value, %{"$ref" => "#/" <> path}, root) do
    schema = get_in(root, String.split(path, "/")) || %{}
    int64_strings(value, schema, root)
  end

  defp int64_strings(value, %{"type" => "integer", "format" => format}, _)
       when format in ["int64", "uint64"] and is_integer(value), do: Integer.to_string(value)

  defp int64_strings(value, schema, root) when is_map(value),
    do:
      Map.new(value, fn {key, item} ->
        {key, int64_strings(item, get_in(schema, ["properties", key]) || %{}, root)}
      end)

  defp int64_strings(value, schema, root) when is_list(value),
    do: Enum.map(value, &int64_strings(&1, schema["items"] || %{}, root))

  defp int64_strings(value, _, _), do: value
end
