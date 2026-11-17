defmodule Ankole.Connectors.Gateway do
  @moduledoc "Serves the same stateless MCP contract to Workers and Function Runtime."
  alias Ankole.Connectors.{
    Approvals,
    AuthWaits,
    Credentials,
    OAuth,
    Registry,
    RemoteMCP,
    ToolSpec,
    WriteReceipts
  }

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

  defp call({:toolkit, id} = target, name, args, context, options)
       when is_binary(name) and is_map(args) do
    with {:ok, adapter, spec, args, credentials} <-
           prepare_toolkit(id, name, args, context, options),
         :allow <-
           Approvals.intercept_or_allow(
             target,
             name,
             spec.annotations,
             args,
             context,
             options,
             credentials.auth_config.public_metadata,
             %{
               "connection" => credentials.auth_config.slug,
               "connection_name" =>
                 credentials.auth_config.display_name || credentials.auth_config.slug,
               "auth_config_id" => credentials.auth_config.id,
               "account" => options["account"],
               "account_id" => credentials[:account] && credentials[:account].id,
               "subject_kind" =>
                 (credentials[:account] && credentials[:account].subject_kind) || "app",
               "account_owner_uid" =>
                 credentials[:account] && credentials[:account].owner_principal_uid
             }
           ),
         {:ok, result, _used_context} <-
           invoke_toolkit(adapter, spec, args, Map.merge(credentials, context)),
         {:ok, result} <- validate_output(spec, result) do
      {:ok, result_content(int64_strings(result, spec.output_schema, spec.output_schema))}
    else
      {:halt, blocked} -> blocked
      other -> other
    end
    |> consent_return(context, id, name)
  end

  defp call({:skill, skill, server} = target, name, args, context, options)
       when is_binary(name) and is_map(args) do
    with {:ok, declaration, tool, args} <- prepare_skill_call(target, name, args, context),
         idempotent? =
           get_in(tool, ["annotations", "readOnlyHint"]) == true or
             get_in(tool, ["annotations", "idempotentHint"]) == true,
         :allow <-
           Approvals.intercept_or_allow(
             target,
             name,
             tool["annotations"] || %{},
             args,
             context,
             options,
             declaration,
             %{"skill" => skill, "server" => server}
           ),
         {:ok, result} <-
           WriteReceipts.execute_skill(skill, server, name, idempotent?, args, context, fn ->
             RemoteMCP.call(
               declaration["url"],
               declaration["headers"],
               name,
               args,
               Keyword.put(remote_options(context, declaration), :idempotent, idempotent?)
             )
           end) do
      schema = tool["outputSchema"] || %{}

      case result do
        %{"structuredContent" => content} ->
          {:ok, Map.put(result, "structuredContent", int64_strings(content, schema, schema))}

        _ ->
          {:ok, result}
      end
    else
      {:halt, blocked} -> blocked
      other -> other
    end
  end

  defp call(_, _, _, _, _), do: {:error, :invalid_request}

  @doc "Executes a human-confirmed `connectors.tool.call` ActionCard at most once."
  def execute_approved_card(card, approver_actor) do
    with {:ok, target, tool_name, args} <- Approvals.verify_locked_payload(card.payload),
         {:ok, %{status: :active} = agent_principal} <-
           Ankole.Principals.get_principal(card.agent_uid) do
      context = %{
        actor: Ankole.AuthZ.Actor.new(agent_principal),
        deadline: System.monotonic_time(:millisecond) + 60_000
      }

      options = %{
        "connection" => card.payload["auth_config_id"] || card.payload["connection"],
        "account" => card.payload["account"],
        approved_card: true,
        locked_auth_config_id: card.payload["auth_config_id"],
        has_locked_account_id: Map.has_key?(card.payload, "account_id"),
        locked_account_id: card.payload["account_id"]
      }

      toolkit_label =
        case target do
          {:toolkit, id} -> id
          {:skill, _skill, server} -> server
        end

      connection_label =
        card.payload["connection_name"] || card.payload["connection"] ||
          card.payload["server"] || toolkit_label

      raw_outcome =
        WriteReceipts.execute_scope(
          "action_card:" <> card.id,
          WriteReceipts.card_target_identity(target, card.payload),
          tool_name,
          args,
          fn ->
            case call(target, tool_name, args, context, options) do
              {:ok, %{"isError" => true} = result} -> {:error, mcp_tool_error(result)}
              {:ok, result} -> {:ok, result, context}
              {:error, _} = err -> err
            end
          end,
          recover_settled?: (card.execution_attempts || 0) > 1
        )

      case raw_outcome do
        {:error, %{code: "write_already_in_flight"}} ->
          {:error, :conflict}

        {:error, %{code: "approved_identity_changed"}} ->
          {:stale,
           "The approved connector connection or account changed since this card was prepared."}

        _ ->
          {outcome_kind, {audit_status, receipt_note}} =
            case raw_outcome do
              {:recovered, %{status: "succeeded"} = receipt} ->
                {:succeeded,
                 Approvals.format_recovered_receipt(tool_name, connection_label, receipt)}

              {:recovered, receipt} ->
                {:failed_uncertain,
                 Approvals.format_recovered_receipt(tool_name, connection_label, receipt)}

              {:ok, result, _ctx} ->
                {:succeeded,
                 Approvals.format_execution_receipt(tool_name, connection_label, {:ok, result})}

              {:error, err} = err_tuple ->
                {classify_failure_outcome(err),
                 Approvals.format_execution_receipt(tool_name, connection_label, err_tuple)}
            end

          Ankole.Logging.info(
            "connectors.approval_executed",
            "Executed approved connector tool call",
            %{
              card_id: card.id,
              approver_uid: Ankole.AuthZ.Actor.uid(approver_actor),
              agent_uid: card.agent_uid,
              tool_name: tool_name,
              connection: card.payload["connection"] || card.payload["server"],
              account: card.payload["account_id"] || card.payload["account"],
              status: audit_status
            }
          )

          {:ok, outcome_kind, receipt_note}
      end
    else
      {:error, :tampered} ->
        {:stale, "Locked tool arguments failed integrity verification."}

      {:error, :not_found} ->
        {:stale, "The requesting Agent no longer exists."}

      {:ok, _disabled_agent} ->
        {:stale, "The requesting Agent is no longer active."}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp consent_return({:error, %{code: "oauth_consent_required"} = error}, context, toolkit, name) do
    resolved_error =
      case return_path(context) do
        nil ->
          error

        path ->
          url = URI.parse(error.authorization_url)
          params = URI.decode_query(url.query || "") |> Map.put("intent", path)
          %{error | authorization_url: URI.to_string(%{url | query: URI.encode_query(params)})}
      end

    AuthWaits.record_blocked_turn(resolved_error, context, toolkit, name)
    {:error, resolved_error}
  end

  defp consent_return(result, _context, _toolkit, _name), do: result

  defp return_path(%{return_to: path}) when is_binary(path), do: path

  defp return_path(%{actor: %{turn_authority: {%Ankole.Sessions.RunRef{} = ref, _uid}}}) do
    with {:conversation, id} <- Ankole.Sessions.Key.parse(ref.session_id),
         {:ok, %{kind: :native}} <- Ankole.Conversations.get_conversation(id),
         do: AnkoleWeb.PodURL.conversation_path(id),
         else: (_ -> nil)
  end

  defp return_path(_context), do: nil

  @doc false
  def invoke_toolkit(adapter, spec, args, context) do
    Ankole.Connectors.WriteReceipts.execute(spec, args, context, fn ->
      case adapter.call(spec, args, context) do
        {:ok, result} ->
          {:ok, result, context}

        {:error, %{status: 401} = error} ->
          recover_token(adapter, spec, args, context, error)

        result ->
          result
      end
    end)
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
        scopes =
          Enum.uniq(((context.account && context.account.granted_scopes) || []) ++ spec.scopes)

        {:error, map} =
          OAuth.consent_required(context.auth_config.slug, scopes, %{
            "toolkit" => spec.toolkit,
            "subject_kind" => (context.account && context.account.subject_kind) || "app"
          })

        {:error, Map.put(map, :request_sent, false)}

      {:error, reason} when reason in [:oauth_refresh_failed, :oauth_refresh_cooling_down] ->
        {:error,
         %{
           code: Atom.to_string(reason),
           message: "The connection could not be refreshed. Retry shortly.",
           retryable: true,
           retryAfterSeconds: 30,
           request_sent: false
         }}

      result ->
        result
    end
  end

  defp classify_failure_outcome(err) do
    if WriteReceipts.uncertain_failure?(err), do: :failed_uncertain, else: :failed_not_sent
  end

  defp mcp_tool_error(result) when is_map(result) do
    %{
      code: "mcp_tool_error",
      message: extract_mcp_error_message(result),
      status: 200,
      retryable: false,
      request_sent: true
    }
  end

  defp extract_mcp_error_message(%{"content" => content}) when is_list(content) do
    Enum.find_value(content, fn
      %{"text" => text} when is_binary(text) ->
        trimmed = String.trim(text)
        if trimmed != "", do: trimmed

      _ ->
        nil
    end) || "Remote MCP tool reported an error"
  end

  defp extract_mcp_error_message(result) when is_map(result) do
    case Map.get(result, "message") || Map.get(result, "error") do
      text when is_binary(text) ->
        trimmed = String.trim(text)
        if trimmed != "", do: trimmed, else: "Remote MCP tool reported an error"

      _ ->
        "Remote MCP tool reported an error"
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
         :ok <- verify_locked_card_targets(options),
         {:ok, credentials} <-
           Ankole.Connectors.resolve_call(
             spec,
             context.actor.principal,
             options["connection"],
             options["account"],
             args
           ),
         :ok <- verify_locked_card_credentials(credentials, options) do
      {:ok, adapter, spec, args, credentials}
    else
      error -> pre_invocation_error(error)
    end
  end

  defp verify_locked_card_targets(%{approved_card: true} = options) do
    locked_config_id = options[:locked_auth_config_id]
    locked_account_id = options[:locked_account_id]

    with :ok <- verify_locked_auth_config_exists(locked_config_id),
         :ok <- verify_locked_account_exists(locked_account_id, locked_config_id) do
      :ok
    end
  end

  defp verify_locked_card_targets(_options), do: :ok

  defp verify_locked_auth_config_exists(id) when is_binary(id) do
    case Ankole.Connectors.Store.get_auth_config_for_configuration(id) do
      {:ok, _config} -> :ok
      _ -> {:error, :approved_identity_changed}
    end
  end

  defp verify_locked_auth_config_exists(_), do: :ok

  defp verify_locked_account_exists(account_id, config_id) when is_binary(account_id) do
    case Ankole.Connectors.get_account_by_id(account_id) do
      {:ok, %{status: "active"} = account} ->
        if is_nil(config_id) or account.auth_config_id == config_id,
          do: :ok,
          else: {:error, :approved_identity_changed}

      _ ->
        {:error, :approved_identity_changed}
    end
  end

  defp verify_locked_account_exists(_, _), do: :ok

  defp verify_locked_card_credentials(credentials, %{approved_card: true} = options) do
    locked_config_id = options[:locked_auth_config_id]
    resolved_account_id = credentials[:account] && credentials[:account].id

    cond do
      is_binary(locked_config_id) and credentials.auth_config.id != locked_config_id ->
        {:error, :approved_identity_changed}

      options[:has_locked_account_id] == true and
          resolved_account_id != options[:locked_account_id] ->
        {:error, :approved_identity_changed}

      true ->
        :ok
    end
  end

  defp verify_locked_card_credentials(_credentials, _options), do: :ok

  defp prepare_skill_call({:skill, skill, server} = target, name, args, context) do
    with {:ok, declaration} <- skill_server(context, skill, server),
         true <- allowed?(declaration, name),
         {:ok, tools} <- tools(target, context),
         %{} = tool <- Enum.find(tools, &(&1["name"] == name)),
         :ok <- readonly(context, tool["annotations"] || %{}),
         {:ok, args} <- Ankole.Sessions.ToolArguments.validate(tool["inputSchema"] || %{}, args) do
      {:ok, declaration, tool, args}
    else
      false -> pre_invocation_error({:error, :mcp_tool_not_enabled})
      error -> pre_invocation_error(error)
    end
  end

  defp pre_invocation_error(nil),
    do: {:error, %{code: "mcp_tool_not_found", request_sent: false, retryable: false}}

  defp pre_invocation_error({:error, reason}) when is_binary(reason),
    do:
      {:error,
       %{code: "invalid_tool_arguments", message: reason, retryable: false, request_sent: false}}

  defp pre_invocation_error({:error, reason}) when is_atom(reason),
    do: {:error, %{code: Atom.to_string(reason), retryable: false, request_sent: false}}

  defp pre_invocation_error({:error, reason}) when is_map(reason),
    do: {:error, Map.put(reason, :request_sent, false)}

  defp pre_invocation_error(error), do: error

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
        Ankole.Logging.warning(
          "connectors.gateway.output_schema_drift",
          "Connector upstream response drifted from declared outputSchema; returning payload",
          %{
            tenant_id: Ankole.Repo.tenant_id(),
            toolkit: spec.toolkit,
            tool: spec.name,
            reason: reason
          }
        )

        {:ok, result}

      validated ->
        validated
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
