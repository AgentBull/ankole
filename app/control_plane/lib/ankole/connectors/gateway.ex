defmodule Ankole.Connectors.Gateway do
  @moduledoc "Serves the same stateless MCP contract to Workers and Function Runtime."
  alias Ankole.Connectors.{Credentials, OAuth, Registry, RemoteMCP, ToolSpec}

  def request(target, %{"method" => method} = request, context, options) do
    params = request["params"] || %{}

    case method do
      "server/discover" ->
        {:ok,
         %{
           "supportedVersions" => ["2026-07-28"],
           "capabilities" => %{"tools" => %{}},
           "ttlMs" => 0,
           "cacheScope" => "private"
         }}

      "initialize" ->
        {:ok,
         %{
           "protocolVersion" => "2026-07-28",
           "capabilities" => %{"tools" => %{}},
           "serverInfo" => %{"name" => "Ankole Connectors", "version" => "1"}
         }}

      "notifications/initialized" ->
        :accepted

      "ping" ->
        {:ok, %{}}

      "tools/list" ->
        with {:ok, tools} <- tools(target, context),
             do:
               {:ok,
                %{
                  "tools" => Enum.map(tools, &public_tool/1),
                  "ttlMs" => 0,
                  "cacheScope" => "private"
                }}

      "tools/call" ->
        call(target, params["name"], params["arguments"] || %{}, context, options)

      _ ->
        {:error, :method_not_found}
    end
  end

  def request(_, _, _, _), do: {:error, :invalid_request}

  defp public_tool(%{"outputSchema" => schema} = tool),
    do: Map.put(tool, "outputSchema", ToolSpec.public_output_schema(schema))

  defp public_tool(tool), do: tool

  defp tools({:toolkit, id}, _context) do
    with {:ok, _, specs} <- Registry.toolkit(id), do: {:ok, Enum.map(specs, &ToolSpec.public/1)}
  end

  defp tools({:skill, skill, server}, context) do
    with {:ok, declaration} <- skill_server(context, skill, server),
         {:ok, tools} <-
           RemoteMCP.list_tools(
             declaration["url"],
             declaration["headers"],
             remote_options(context, declaration)
           ) do
      {:ok, Enum.filter(tools, &allowed?(declaration, &1["name"]))}
    end
  end

  defp call({:toolkit, id}, name, args, context, options) when is_binary(name) and is_map(args) do
    with {:ok, adapter, spec, args, credentials} <-
           prepare_toolkit(id, name, args, context, options),
         {:ok, result, _used_context} <-
           invoke_toolkit(adapter, spec, args, Map.merge(credentials, context)),
         {:ok, result} <- validate_output(spec, result) do
      {:ok, result_content(int64_strings(result, spec.output_schema, spec.output_schema))}
    end
  end

  defp call({:skill, skill, server} = target, name, args, context, _options)
       when is_binary(name) and is_map(args) do
    with {:ok, declaration} <- skill_server(context, skill, server),
         true <- allowed?(declaration, name),
         {:ok, tools} <- tools(target, context),
         %{} = tool <- Enum.find(tools, &(&1["name"] == name)),
         :ok <- readonly(context, tool["annotations"] || %{}),
         {:ok, args} <- Ankole.Sessions.ToolArguments.validate(tool["inputSchema"] || %{}, args),
         {:ok, result} <-
           RemoteMCP.call(
             declaration["url"],
             declaration["headers"],
             name,
             args,
             Keyword.put(
               remote_options(context, declaration),
               :idempotent,
               get_in(tool, ["annotations", "readOnlyHint"]) == true or
                 get_in(tool, ["annotations", "idempotentHint"]) == true
             )
           ) do
      schema = tool["outputSchema"] || %{}

      case result do
        %{"structuredContent" => content} ->
          {:ok, Map.put(result, "structuredContent", int64_strings(content, schema, schema))}

        _ ->
          {:ok, result}
      end
    else
      false -> {:error, :mcp_tool_not_enabled}
      nil -> {:error, :mcp_tool_not_found}
      error -> error
    end
  end

  defp call(_, _, _, _, _), do: {:error, :invalid_request}

  @doc false
  def invoke_toolkit(adapter, spec, args, context) do
    case adapter.call(spec, args, context) do
      {:ok, result} ->
        {:ok, result, context}

      {:error, %{status: 401} = error} ->
        recover_token(adapter, spec, args, context, error)

      result ->
        result
    end
  end

  defp recover_token(adapter, spec, args, context, error) do
    case Credentials.refresh_rejected_token(
           context.auth_config,
           context.account,
           context.access_token,
           adapter
         ) do
      {:ok, token} ->
        if ToolSpec.retry_safe?(spec) do
          retry_toolkit(adapter, spec, args, %{context | access_token: token})
        else
          {:error,
           Map.merge(error, %{
             retryable: true,
             message: "The connection was refreshed. Retry this operation."
           })}
        end

      {:error, :oauth_reauthorization_required} ->
        OAuth.consent_required(context.auth_config.slug, spec.scopes, %{
          "toolkit" => spec.toolkit,
          "subject_kind" => (context.account && context.account.subject_kind) || "app"
        })

      {:error, reason} when reason in [:oauth_refresh_failed, :oauth_refresh_cooling_down] ->
        {:error,
         %{
           code: Atom.to_string(reason),
           message: "The connection could not be refreshed. Retry shortly.",
           retryable: true,
           retryAfterSeconds: 30,
           request_sent: true
         }}

      result ->
        result
    end
  end

  defp retry_toolkit(adapter, spec, args, context) do
    case adapter.call(spec, args, context) do
      {:ok, result} ->
        {:ok, result, context}

      {:error, %{status: 401}} = error ->
        Credentials.invalidate_access_token(
          context.auth_config,
          context.account,
          context.access_token
        )

        error

      result ->
        result
    end
  end

  defp prepare_toolkit(id, name, args, context, options) do
    with {:ok, adapter, specs} <- Registry.toolkit(id),
         %{} = spec <- Enum.find(specs, &(&1.name == name)),
         :ok <- readonly(context, spec.annotations),
         {:ok, args} <- ToolSpec.validate_input(spec, args),
         {:ok, credentials} <-
           Ankole.Connectors.resolve_call(
             spec,
             context.actor.principal,
             options["connection"],
             options["account"],
             args
           ) do
      {:ok, adapter, spec, args, credentials}
    else
      nil ->
        {:error, %{code: "mcp_tool_not_found", request_sent: false, retryable: false}}

      {:error, reason} when is_binary(reason) ->
        {:error,
         %{code: "invalid_tool_arguments", message: reason, retryable: false, request_sent: false}}

      {:error, reason} when is_atom(reason) ->
        {:error, %{code: Atom.to_string(reason), retryable: false, request_sent: false}}

      {:error, reason} when is_map(reason) ->
        {:error, Map.put(reason, :request_sent, false)}

      error ->
        error
    end
  end

  defp skill_server(context, skill, server) do
    with {:ok, projection} <-
           Ankole.BackgroundAgentJobs.RuntimeProjection.for_turn(context.actor.turn_authority),
         {:ok, %{"transport" => "streamable_http"} = declaration} <-
           Ankole.AIAgent.resolve_mcp_server(context.actor.principal, skill, server,
             runtime_projection: projection
           ),
         do: {:ok, declaration},
         else: (
           {:ok, _} -> {:error, :mcp_requires_http_transport}
           error -> error
         )
  end

  defp remote_options(context, declaration),
    do: [
      deadline: context.deadline,
      protocol_version: declaration["protocol_version"],
      cache_key: context.actor.principal.uid
    ]

  defp allowed?(declaration, name),
    do:
      name not in (declaration["disabled_tools"] || []) and
        (is_nil(declaration["enabled_tools"]) or name in declaration["enabled_tools"])

  defp readonly(%{read_only: true}, annotations) do
    if annotations["readOnlyHint"] == true, do: :ok, else: {:error, :read_only_route}
  end

  defp readonly(_, _), do: :ok

  defp result_content(result),
    do: %{
      "structuredContent" => result,
      "content" => [%{"type" => "text", "text" => Torque.encode!(result)}],
      "isError" => false
    }

  defp validate_output(spec, result) do
    case ToolSpec.validate_output(spec, result) do
      {:error, reason} ->
        {:error, %{code: "invalid_upstream_output", message: reason, retryable: false}}

      result ->
        result
    end
  end

  defp int64_strings(value, %{"$ref" => "#/" <> path}, root),
    do: int64_strings(value, get_in(root, String.split(path, "/")) || %{}, root)

  defp int64_strings(value, %{"type" => "integer", "format" => format}, _)
       when format in ["int64", "uint64"] and is_integer(value), do: Integer.to_string(value)

  defp int64_strings(value, %{"allOf" => schemas} = schema, root),
    do: union_strings(value, schemas, schema, "allOf", root)

  defp int64_strings(value, %{"anyOf" => schemas} = schema, root),
    do: union_strings(value, schemas, schema, "anyOf", root)

  defp int64_strings(value, %{"oneOf" => schemas} = schema, root),
    do: union_strings(value, schemas, schema, "oneOf", root)

  defp int64_strings(value, schema, root) when is_map(value),
    do:
      Map.new(value, fn {key, item} ->
        {key, int64_strings(item, get_in(schema, ["properties", key]) || %{}, root)}
      end)

  defp int64_strings(value, schema, root) when is_list(value),
    do: Enum.map(value, &int64_strings(&1, schema["items"] || %{}, root))

  defp int64_strings(value, _, _), do: value

  defp union_strings(value, schemas, schema, keyword, root) do
    Enum.reduce(
      schemas,
      int64_strings(value, Map.delete(schema, keyword), root),
      &int64_strings(&2, &1, root)
    )
  end
end
