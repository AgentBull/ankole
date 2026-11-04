defmodule Ankole.Plugins.CloudConnectorsAdapter.Adapter do
  @moduledoc false
  alias Ankole.Connectors.{Accounts, CloudProvider, Credentials}
  alias Ankole.Plugins.CloudConnectorsAdapter.{Definitions, Protocol}

  def call(id, tool, args, context) do
    with {:ok, credentials} <- credentials(context),
         {:ok, auth} <- Protocol.auth_params(id, context.auth_config, credentials),
         {:ok, result} <-
           CloudProvider.execute_tool(%{
             "tenant_id" => context.auth_config.tenant_id,
             "plugin_id" => id,
             "slug" => tool.operation["slug"],
             "version" => tool.operation["version"],
             "arguments" => args,
             "idempotent" => Ankole.Connectors.ToolSpec.retry_safe?(tool),
             "custom_auth_params" => auth
           }) do
      {:ok, public_result(%{"result" => result}, tool.output_validator || tool.output_schema)}
    end
  end

  def reconcile_trigger(id, config, secret, trigger, desired) do
    with {:ok, account} <- Accounts.get_by_id(trigger.connected_account_id),
         true <- not is_nil(account),
         {:ok, credentials} <- trigger_credentials(id, config, secret, account, desired),
         {:ok, polling} <- polling(id, trigger),
         request <-
           Map.merge(
             %{
               "tenant_id" => config.tenant_id,
               "plugin_id" => id,
               "pod_trigger_id" => trigger.id,
               "account_key" => account_key(id, account),
               "upstream_connection_id" => account.upstream_connection_id,
               "credentials" => credentials,
               "event_type" => trigger.trigger_type,
               "scope_key" => trigger.scope_key,
               "resource_scope" => Map.put(trigger.config, "scope_key", trigger.scope_key),
               "config" => trigger.config,
               "desired" => desired
             },
             polling
           ),
         {:ok, result} <- CloudProvider.reconcile_trigger(request) do
      {:ok, %{external_subscription_id: result["external_subscription_id"]}}
    else
      false -> {:error, :connection_account_required}
      error -> error
    end
  end

  defp trigger_credentials(_id, _config, _secret, %{upstream_connection_id: upstream}, _desired)
       when is_binary(upstream), do: {:ok, %{}}

  defp trigger_credentials(id, config, secret, account, desired) do
    with {:ok, token} <-
           Credentials.subscription_token(config, account, Definitions.module(id), desired),
         {:ok, credentials} <-
           credentials(%{auth_config: config, account: account, access_token: token}) do
      if id == "trello",
        do:
          {:ok,
           Map.put(
             credentials,
             "application_secret",
             secret["clientSecret"] || secret["client_secret"]
           )},
        else: {:ok, credentials}
    end
  end

  defp account_key("stripe", account), do: account.external_subject_id
  defp account_key("zendesk", account), do: account.public_metadata["subdomain"]
  defp account_key(_, account), do: account.id

  defp polling("googlecalendar", trigger) do
    slug =
      %{
        "googlecalendar.event.created" => "GOOGLECALENDAR_GOOGLE_CALENDAR_EVENT_CREATED_TRIGGER",
        "googlecalendar.event.updated" => "GOOGLECALENDAR_GOOGLE_CALENDAR_EVENT_UPDATED_TRIGGER",
        "googlecalendar.event.canceled" => "GOOGLECALENDAR_EVENT_CANCELED_DELETED_TRIGGER"
      }[trigger.trigger_type]

    {:ok,
     %{
       "upstream_trigger_slug" => slug,
       "toolkit_version" => "20261103_00",
       "trigger_config" => Map.put(trigger.config, "calendarId", trigger.scope_key)
     }}
  end

  defp polling("salesforce", %{trigger_type: "salesforce.record.updated"} = trigger),
    do:
      {:ok,
       %{
         "upstream_trigger_slug" => "SALESFORCE_GENERIC_S_OBJECT_RECORD_UPDATED_TRIGGER",
         "toolkit_version" => "20261103_00",
         "trigger_config" => Map.put(trigger.config, "sobject_name", trigger.scope_key)
       }}

  defp polling("salesforce", %{trigger_type: "salesforce.record.created"} = trigger) do
    case %{
           "Lead" => "SALESFORCE_NEW_LEAD_TRIGGER",
           "Contact" => "SALESFORCE_NEW_CONTACT_TRIGGER"
         }[trigger.scope_key] do
      nil ->
        {:error,
         %{
           code: "unsupported_salesforce_object",
           message:
             "Creation events support Lead and Contact. Use record.updated for other Salesforce objects.",
           retryable: false
         }}

      slug ->
        {:ok,
         %{
           "upstream_trigger_slug" => slug,
           "toolkit_version" => "20261103_00",
           "trigger_config" => trigger.config
         }}
    end
  end

  defp polling(_, _), do: {:ok, %{}}

  defp credentials(%{account: %{sealed_credentials: sealed} = account, access_token: token})
       when is_binary(sealed) do
    with {:ok, credentials} <- Credentials.account_credentials(account),
         do:
           {:ok,
            credentials
            |> Map.put("access_token", token)
            |> Map.put_new("public_metadata", account.public_metadata)}
  end

  defp credentials(%{account: account, access_token: token}),
    do:
      {:ok,
       %{
         "access_token" => token,
         "public_metadata" => if(account, do: account.public_metadata, else: %{})
       }}

  @doc false
  def public_result(value, %ExJsonSchema.Schema.Root{} = root),
    do: normalize_schema(value, root.schema, root)

  def public_result(value, schema),
    do: public_result(value, Ankole.Sessions.ToolArguments.resolve(schema))

  defp normalize_schema(value, %{"$ref" => ref} = schema, root) do
    target = ExJsonSchema.Schema.get_fragment!(root, ref)
    normalize_schema(value, Map.merge(target, Map.delete(schema, "$ref")), root)
  end

  defp normalize_schema(value, schema, root) when is_map(schema) do
    case Enum.find(["anyOf", "oneOf", "allOf"], &Map.has_key?(schema, &1)) do
      nil ->
        normalize_result(value, schema, root)

      "allOf" ->
        normalize_schema(
          value,
          Enum.reduce(schema["allOf"], Map.delete(schema, "allOf"), &merge_schema/2),
          root
        )

      key ->
        normalize_union(value, Map.delete(schema, key), schema[key], root)
    end
  end

  defp normalize_schema(value, _schema, root), do: normalize_result(value, %{}, root)

  defp normalize_union(value, base, branches, root) do
    Enum.find_value(branches, fn branch ->
      schema = merge_schema(branch, base)
      result = normalize_schema(value, schema, root)

      case validate_fragment(schema, result, root) do
        :ok -> {:ok, result}
        {:error, _} -> nil
      end
    end)
    |> case do
      {:ok, result} -> result
      nil -> normalize_result(value, base, root)
    end
  end

  defp merge_schema(branch, base) do
    merged = Map.merge(base, branch)

    merged =
      if base["properties"],
        do:
          Map.put(
            merged,
            "properties",
            Map.merge(base["properties"], branch["properties"] || %{})
          ),
        else: merged

    if base["required"],
      do: Map.put(merged, "required", Enum.uniq(base["required"] ++ (branch["required"] || []))),
      else: merged
  end

  defp normalize_result(value, schema, root) when is_map(value) do
    properties = schema["properties"] || %{}
    required = schema["required"] || []

    value
    |> Map.delete("composio_execution_message")
    |> Enum.reject(fn {key, item} ->
      is_nil(item) and key not in required and Map.has_key?(properties, key) and
        match?({:error, _}, validate_fragment(properties[key], nil, root))
    end)
    |> Map.new(fn {key, item} ->
      {key, normalize_schema(item, properties[key] || schema["additionalProperties"], root)}
    end)
  end

  defp normalize_result(value, schema, root) when is_list(value),
    do: Enum.map(value, &normalize_schema(&1, schema["items"], root))

  defp normalize_result(value, _schema, _root), do: value

  defp validate_fragment(schema, value, root),
    do: ExJsonSchema.Validator.validate_fragment(root, schema, value)
end
