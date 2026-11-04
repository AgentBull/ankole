defmodule Ankole.Plugins.LarkAdapter.Connector do
  @moduledoc "Lark business tools with application authentication and verified employee identity."
  @behaviour Ankole.Connectors.Connector
  alias Ankole.Connectors.{Files, HTTP}
  alias Ankole.Plugins.LarkAdapter.{ConnectorArguments, Toolkits}

  def tools,
    do:
      Toolkits.IM.tools() ++
        Toolkits.Approvals.tools() ++ Toolkits.Tasks.tools() ++ Toolkits.Calendar.tools()

  def upstream_auth(%{toolkit: toolkit, upstream_auth: :adaptive_token}, human, args)
      when toolkit in ["lark_tasks", "lark_calendar"] and not is_nil(human) do
    if args["resource_scope"] == "app", do: :app_token, else: :human_oauth_token
  end

  def upstream_auth(tool, _human, _args), do: tool.upstream_auth

  def call(%{name: "im_upload_file"}, args, context) do
    {path, field, fields} =
      if args["file_type"] == "image",
        do: {"/open-apis/im/v1/images", "image", %{"image_type" => "message"}},
        else:
          {"/open-apis/im/v1/files", "file",
           Map.take(args, ["file_type", "file_name", "duration"])}

    with {:ok, response} <-
           Files.multipart(
             context.actor,
             args["file_ref"],
             base_url(context.auth_config) <> path,
             auth_headers(context.access_token),
             fields,
             field,
             args["file_name"],
             request_options(context)
           ),
         {:ok, result} <- HTTP.decode(response),
         do: response(result, context)
  end

  def call(%{name: "approvals_upload_file"}, args, context) do
    with {:ok, response} <-
           Files.multipart(
             context.actor,
             args["file_ref"],
             base_url(context.auth_config) <> "/open-apis/approval/v4/files/upload",
             auth_headers(context.access_token),
             Map.take(args, ["name", "type"]),
             "content",
             args["name"],
             request_options(context)
           ),
         {:ok, result} <- HTTP.decode(response),
         do: response(result, context)
  end

  def call(%{name: "im_download_resource"} = tool, args, context) do
    with {:ok, url, _} <- HTTP.request_parts(tool.operation, args, base_url(context.auth_config)),
         do:
           Files.download(
             context.actor,
             url,
             auth_headers(context.access_token),
             args["destination"],
             request_options(context)
           )
  end

  def call(%{name: name} = tool, args, context)
      when name in ["tasks_complete", "tasks_uncomplete"] do
    with {:ok, current} <-
           call(find_tool("tasks_get"), Map.take(args, ["task_guid", "resource_scope"]), context) do
      complete? = get_in(current, ["task", "completed_at"]) not in [nil, "0", 0, ""]
      desired? = name == "tasks_complete"

      if complete? == desired? do
        {:ok, current}
      else
        args =
          Map.put(args, "task", %{
            "completed_at" =>
              if(desired?, do: Integer.to_string(System.system_time(:millisecond)), else: "0")
          })
          |> Map.put("update_fields", ["completed_at"])

        request(tool, args, context)
      end
    end
  end

  def call(%{name: "calendar_create_event"} = tool, args, context) do
    with {:ok, args} <- ConnectorArguments.prepare(tool, args, context),
         {:ok, result} <- request(tool, Map.delete(args, "attendees"), context) do
      case args["attendees"] do
        attendees when is_list(attendees) and attendees != [] ->
          event_id = get_in(result, ["event", "event_id"])

          case call(
                 find_tool("calendar_manage_attendees"),
                 %{
                   "calendar_id" => args["calendar_id"],
                   "event_id" => event_id,
                   "operation" => "add",
                   "attendees" => attendees
                 },
                 context
               ) do
            {:ok, _} ->
              {:ok, result}

            {:error, cause} ->
              {:error,
               %{
                 code: "partial_write_completed",
                 retryable: false,
                 completed_step: "create_event",
                 resource_id: event_id,
                 failed_step: "add_attendees",
                 cause: cause
               }}
          end

        _ ->
          {:ok, result}
      end
    end
  end

  def call(tool, args, context) do
    with {:ok, args} <- ConnectorArguments.prepare(tool, args, context),
         do: request(tool, args, context)
  end

  def request(tool, args, context) do
    {operation, args} = ConnectorArguments.operation(tool, args)

    with {:ok, result} <-
           HTTP.call(
             %{tool | operation: operation},
             args,
             base_url(context.auth_config),
             headers(context.access_token),
             request_options(context)
           ),
         {:ok, data} <- response(result, context) do
      {:ok, decode_forms(data)}
    end
  end

  defp response(result, context) do
    case unwrap(result) do
      {:error, %{upstream_code: code}} = error
      when code in [99_991_663, 99_991_668, 99_991_677] ->
        Ankole.Connectors.Credentials.invalidate_access_token(
          context.auth_config,
          context.account,
          context.access_token
        )

        redact_error(error, context.access_token)

      {:error, _} = error ->
        redact_error(error, context.access_token)

      result ->
        result
    end
  end

  defp redact_error({:error, reason}, token),
    do: {:error, HTTP.redact_credentials(reason, headers(token))}

  def find_tool(name), do: Enum.find(tools(), &(&1.name == name))

  def reconcile_trigger(config, _secret, trigger, desired?) do
    with {:ok, account} <- Ankole.Connectors.get_account_by_id(trigger.connected_account_id),
         :ok <- subscription_account(trigger, account),
         {:ok, token} <-
           Ankole.Connectors.Credentials.subscription_token(config, account, __MODULE__, desired?),
         {:ok, path} <- subscription_path(trigger, desired?),
         {:ok, _} <- subscription_request(config, token, path) do
      {:ok, %{external_subscription_id: if(desired?, do: trigger.scope_key)}}
    end
  end

  defp subscription_request(config, token, path) do
    result =
      with {:ok, response} <-
             Ankole.Files.HTTP.request("POST", base_url(config) <> path, headers(token), "{}",
               idempotent: true
             ),
           {:ok, result} <- HTTP.decode(response, idempotent: true),
           do: unwrap(result)

    case result do
      {:error, reason} -> {:error, HTTP.redact_credentials(reason, headers(token))}
      result -> result
    end
  end

  defp subscription_account(%{trigger_type: "lark_calendar"}, %{subject_kind: "human"}), do: :ok

  defp subscription_account(%{trigger_type: "lark_calendar"}, _),
    do: {:error, :oauth_consent_required}

  defp subscription_account(_, _), do: :ok

  defp subscription_path(%{trigger_type: "lark_approval", scope_key: code}, desired?),
    do:
      {:ok,
       "/open-apis/approval/v4/approvals/" <>
         URI.encode(code, &URI.char_unreserved?/1) <>
         if(desired?, do: "/subscribe", else: "/unsubscribe")}

  defp subscription_path(%{trigger_type: "lark_calendar", scope_key: id}, desired?),
    do:
      {:ok,
       "/open-apis/calendar/v4/calendars/" <>
         URI.encode(id, &URI.char_unreserved?/1) <>
         "/events/" <> if(desired?, do: "subscription", else: "unsubscription")}

  defp subscription_path(_, _), do: {:error, :unsupported_trigger_type}

  def webhook(config, secret, raw_body, headers) do
    verification = %{
      verification_token: secret["verification_token"] || secret["verificationToken"],
      encrypt_key: secret["encrypt_key"] || secret["encryptKey"]
    }

    with true <- not is_nil(verification.verification_token || verification.encrypt_key),
         {:ok, decoded} <- FeishuOpenAPI.Event.Envelope.decode(raw_body, verification.encrypt_key) do
      if is_map(decoded["action"]) do
        with {:ok, action} <-
               FeishuOpenAPI.CardAction.verify_and_decode(verification, raw_body, headers),
             do: Ankole.Plugins.LarkAdapter.ConnectorEvents.signal(config, card_event(action))
      else
        with {:ok, event} <-
               FeishuOpenAPI.Event.verify_and_decode(verification, raw_body, headers),
             do: Ankole.Plugins.LarkAdapter.ConnectorEvents.signal(config, event)
      end
    else
      false -> {:error, :invalid_webhook_signature}
      error -> error
    end
  end

  defp card_event(action) do
    %FeishuOpenAPI.Event{
      id:
        "card:" <>
          Base.encode16(:crypto.hash(:sha256, action.token || Torque.encode!(action.raw)),
            case: :lower
          ),
      type: "card.action.trigger",
      content: %{
        "operator" => %{
          "user_id" => action.user_id,
          "open_id" => action.open_id,
          "tenant_key" => action.tenant_key
        },
        "context" => %{
          "open_message_id" => action.open_message_id,
          "open_chat_id" => action.open_chat_id
        },
        "token" => action.token,
        "action" => action.action
      },
      raw: action.raw
    }
  end

  def webhook_response(%{"type" => "card.action.trigger", "id" => "card:" <> _}), do: %{}

  def webhook_response(%{"type" => "card.action.trigger"}),
    do: %{"toast" => %{"type" => "success", "content" => "Request received."}}

  def webhook_response(_event), do: %{}

  def event_references(config, event),
    do:
      Ankole.Plugins.LarkAdapter.ConnectorEvents.references(
        config.id,
        event["type"],
        event["data"]
      )

  def fetch_app_token(config, secret, _account) do
    body = %{
      "app_id" => secret["app_id"] || secret["appID"] || config.public_metadata["appID"],
      "app_secret" => secret["app_secret"] || secret["appSecret"]
    }

    with {:ok,
          %{
            status: status,
            body: %{"code" => 0, "tenant_access_token" => token, "expire" => expire}
          }}
         when status in 200..299 <-
           Ankole.Files.HTTP.json(
             "POST",
             base_url(config) <> "/open-apis/auth/v3/tenant_access_token/internal",
             [{"content-type", "application/json"}],
             body,
             idempotent: true
           ) do
      {:ok, %{access_token: token, expires_in: expire}}
    else
      {:error, _} = error -> error
      _ -> {:error, :upstream_token_rejected}
    end
  end

  def oauth_authorize_url(config, secret, params) do
    scopes =
      (String.split(params["scope"] || "", ~r/[ ,]+/, trim: true) ++
         ["offline_access", "contact:user.employee_id:readonly"])
      |> Enum.uniq()
      |> Enum.join(" ")

    params =
      Map.merge(Map.delete(params, :subject_kind), %{
        "client_id" => secret["app_id"] || secret["appID"] || config.public_metadata["appID"],
        "response_type" => "code",
        "scope" => scopes
      })

    host =
      if config.public_metadata["domain"] == "lark",
        do: "https://accounts.larksuite.com",
        else: "https://accounts.feishu.cn"

    {:ok, host <> "/open-apis/authen/v1/authorize?" <> URI.encode_query(params)}
  end

  def oauth_exchange(config, secret, params) do
    with {:ok, tokens} <-
           oauth_tokens(config, secret, Map.put(params, "grant_type", "authorization_code")),
         {:ok, user} <- fetch_user(config, tokens["access_token"]) do
      {:ok,
       tokens
       |> Map.put("external_subject_id", user["user_id"] || user["open_id"])
       |> Map.put("public_metadata", user_metadata(user))}
    end
  end

  def user_metadata(user) do
    %{
      "user_id" => user["user_id"],
      "subject_id_type" => if(user["user_id"], do: "user_id", else: "open_id"),
      "name" => user["name"]
    }
  end

  def refresh_token(config, secret, credentials),
    do:
      oauth_tokens(config, secret, %{
        "grant_type" => "refresh_token",
        "refresh_token" => credentials["refresh_token"]
      })

  @doc false
  def oauth_tokens(config, secret, params) do
    params =
      Map.merge(params, %{
        "client_id" => secret["app_id"] || secret["appID"] || config.public_metadata["appID"],
        "client_secret" => secret["app_secret"] || secret["appSecret"]
      })

    with {:ok, %{status: status, body: tokens}} when status in 200..299 <-
           Ankole.Files.HTTP.json(
             "POST",
             base_url(config) <> "/open-apis/authen/v2/oauth/token",
             [{"content-type", "application/json"}],
             params
           ),
         {:ok, tokens} <- unwrap(tokens),
         %{"access_token" => _token} <- tokens do
      {:ok, tokens}
    else
      {:ok, %{body: %{"code" => code}}} when code in [20024, 20026] -> {:error, :invalid_grant}
      {:ok, %{body: %{"error" => "invalid_grant"}}} -> {:error, :invalid_grant}
      {:error, "invalid_grant"} -> {:error, :invalid_grant}
      {:error, _} = error -> error
      _ -> {:error, :oauth_token_rejected}
    end
  end

  defp fetch_user(config, token) do
    with {:ok, %{status: status, body: body}} when status in 200..299 <-
           Ankole.Files.HTTP.request(
             "GET",
             base_url(config) <> "/open-apis/authen/v1/user_info",
             headers(token),
             nil,
             idempotent: true
           ),
         {:ok, decoded} <- Torque.decode(body),
         do: unwrap(decoded)
  end

  def bound_user_id(config, uid) do
    with {:ok, providers} <- identity_providers(config) do
      identities =
        Ankole.Principals.list_external_identities!(
          query: [filter: [principal_uid: uid, provider: [in: providers]]]
        )

      case identities
           |> Enum.filter(&same_external_tenant?(&1, config))
           |> Enum.map(& &1.metadata["user_id"])
           |> Enum.reject(&is_nil/1)
           |> Enum.uniq() do
        [id] -> {:ok, id}
        [] -> account_user_id(config, uid)
        _ -> {:error, :external_identity_ambiguous}
      end
    end
  end

  defp account_user_id(config, uid) do
    with {:ok, account} <- Ankole.Connectors.Accounts.get_account(config.id, "human", uid),
         true <- account != nil and Ankole.Connectors.Accounts.valid?(account),
         id when is_binary(id) and id != "" <-
           account.public_metadata["user_id"] ||
             if(account.public_metadata["subject_id_type"] != "open_id",
               do: account.external_subject_id
             ) do
      {:ok, id}
    else
      _ -> {:error, :oauth_consent_required}
    end
  end

  def principal_for_user(config, user_id) when is_binary(user_id) and user_id != "" do
    with {:ok, providers} <- identity_providers(config) do
      identities = Ankole.Principals.external_identities_by_employee!(providers, user_id)

      case identities
           |> Enum.filter(
             &(&1.metadata["user_id"] == user_id and same_external_tenant?(&1, config))
           )
           |> Enum.map(& &1.principal_uid)
           |> Enum.uniq() do
        [uid] -> {:ok, uid}
        [] -> {:ok, nil}
        _ -> {:error, :external_identity_ambiguous}
      end
    end
  end

  def principal_for_user(_, _), do: {:ok, nil}

  defp identity_providers(config) do
    with {:ok, providers} <- Ankole.IdentityProviders.list_active_provider_refs("lark") do
      {:ok,
       providers
       |> Enum.filter(fn provider ->
         case Ankole.IdentityProviders.provider_config(provider) do
           {:ok, values} ->
             selected = config.public_metadata["identityProvider"]

             if(selected,
               do: selected == provider["provider_id"],
               else: values["authConfigId"] == config.id
             ) and
               (values["domain"] || "feishu") == (config.public_metadata["domain"] || "feishu")

           _ ->
             false
         end
       end)
       |> Enum.map(& &1["provider_id"])}
    end
  end

  defp same_external_tenant?(identity, config),
    do:
      is_nil(config.public_metadata["tenant_key"]) or
        config.public_metadata["tenant_key"] == identity.metadata["tenant_key"]

  def scopes_satisfied?(required, granted, _config) do
    Enum.all?(required, fn scope ->
      scope in granted or
        (String.starts_with?(scope, "calendar:") and "calendar:calendar" in granted) or
        (scope == "calendar:calendar.event:read" and "calendar:calendar:readonly" in granted) or
        (String.starts_with?(scope, "approval:") and "approval:approval" in granted) or
        (String.starts_with?(scope, "task:") and String.ends_with?(scope, ":read") and
           String.replace_suffix(scope, ":read", ":write") in granted)
    end)
  end

  def unwrap(%{"code" => code}) when code in [20024, 20026], do: {:error, :invalid_grant}
  def unwrap(%{"code" => 0, "data" => data}), do: {:ok, data}
  def unwrap(%{"code" => 0} = data), do: {:ok, Map.drop(data, ["code", "msg"])}

  def unwrap(%{"code" => code} = response),
    do:
      {:error,
       %{
         code: "upstream_rejected",
         upstream_code: code,
         message: response["msg"],
         details: response["error"],
         retryable: code in [99_991_663, 99_991_668, 99_991_677]
       }}

  def unwrap(%{"error" => error}), do: {:error, error}
  def unwrap(data) when is_map(data), do: {:ok, data}

  defp decode_forms(value) when is_map(value),
    do:
      Map.new(value, fn
        {"form", value} when is_binary(value) ->
          {"form",
           case Torque.decode(value) do
             {:ok, form} -> form
             _ -> value
           end}

        {key, value} ->
          {key, decode_forms(value)}
      end)

  defp decode_forms(value) when is_list(value), do: Enum.map(value, &decode_forms/1)
  defp decode_forms(value), do: value

  def base_url(config) do
    client_opts =
      Application.get_env(:ankole, Ankole.Plugins.LarkAdapter.Config, [])
      |> Keyword.get(:client_opts, [])

    Keyword.get_lazy(client_opts, :base_url, fn ->
      if config.public_metadata["domain"] == "lark",
        do: "https://open.larksuite.com",
        else: "https://open.feishu.cn"
    end)
  end

  defp request_options(context),
    do: for({:deadline, value} <- context, not is_nil(value), do: {:deadline, value})

  defp headers(token), do: [{"content-type", "application/json"} | auth_headers(token)]
  defp auth_headers(token), do: [{"authorization", "Bearer " <> token}]
end
