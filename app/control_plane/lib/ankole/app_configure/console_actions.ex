defmodule Ankole.AppConfigure.ConsoleActions do
  @moduledoc "Calls the registered setting owner for Console operations."
  use Ash.Resource.Actions.Implementation
  alias Ankole.AppConfigure
  alias Ankole.Errors

  @impl true
  def run(input, opts, _context) do
    scope = Keyword.fetch!(opts, :scope)
    input |> execute(scope) |> Errors.wrap(&describe/1)
  end

  defp execute(%{action: %{name: :console_update_group}, arguments: args}, scope),
    do: AppConfigure.console_update_group(scope, args.group, args.values, args.reset_keys)

  defp execute(%{action: %{name: :console_agent_resolution}, arguments: args}, :tenant),
    do: item(AppConfigure.console_agent_resolution(args.key, args.agent_uid))

  defp execute(
         %{action: %{name: :console_test_mail}, arguments: %{key: "authn.email.mail"} = args},
         :global
       ) do
    with :ok <- Ankole.AppConfigure.Groups.mail_test(args.settings, args.recipient),
         do: {:ok, %{accepted: true}}
  end

  defp execute(%{action: %{name: :console_test_mail}}, _scope),
    do: {:error, :invalid_configuration_group}

  defp execute(%{action: %{name: :console_list}}, scope) do
    with {:ok, items} <- AppConfigure.list_console_items(scope),
         do: {:ok, %{app_configurations: items}}
  end

  defp execute(%{action: %{name: :console_show}, arguments: %{key: key}}, scope),
    do: item(AppConfigure.console_detail(scope, key))

  defp execute(%{action: %{name: :console_update}, arguments: %{key: key}} = input, scope),
    do: item(AppConfigure.console_update(scope, key, Map.take(input.arguments, [:value])))

  defp execute(%{action: %{name: :console_delete}, arguments: %{key: key}}, scope),
    do: item(AppConfigure.console_delete(scope, key))

  defp execute(%{action: %{name: :console_decrypt}, arguments: %{key: key}}, scope) do
    with {:ok, value} <- AppConfigure.console_decrypt(scope, key),
         do: {:ok, %{decrypted_value: %{key: key, value: value}}}
  end

  defp item({:ok, item}), do: {:ok, %{app_configuration: item}}
  defp item(error), do: error

  defp describe({:unknown_key, _}),
    do: Errors.Invalid.NotFound.exception(resource: AppConfigure.ConsoleItem)

  defp describe(:not_found),
    do: Errors.Invalid.NotFound.exception(resource: AppConfigure.ConsoleItem)

  defp describe({:ambiguous_key, _, matches}),
    do: {"This setting matches more than one pattern", [%{matches: matches}]}

  defp describe({:pattern_key_not_editable, _}),
    do: {"Create this pattern setting at site scope first", []}

  defp describe({:key_managed_by_owner, _}),
    do: {"Use the owning settings page to change this value", []}

  defp describe({:pod_scope_only, _}),
    do: {"This setting belongs to a Pod and has no site value", []}

  defp describe({:global_scope_only, _}),
    do: {"This setting is site-wide and cannot be overridden per tenant", []}

  defp describe(:not_encrypted), do: {"This setting is not encrypted", []}

  defp describe(:missing_value),
    do: {"A value is required", [%{path: "value", message: "is required"}]}

  defp describe({:configuration_group_field, key, reason}) do
    {message, fields} = describe(reason) || {"Value is invalid", []}

    details =
      case fields do
        [] -> [%{path: key, message: message}]
        fields -> Enum.map(fields, &Map.update!(&1, :path, fn path -> key <> "." <> path end))
      end

    {key <> ": " <> message, details}
  end

  defp describe(:invalid_configuration_group),
    do: {"This task contains an invalid configuration key or conflicting edits", []}

  defp describe(:incomplete_trace_configuration),
    do: {"Choose a trace provider and endpoint before enabling trace export", []}

  defp describe(:incomplete_turnstile_configuration),
    do: {"Save a site key and secret key before enabling Turnstile", []}

  defp describe(:invalid_test_recipient), do: {"Enter a valid test email recipient", []}

  defp describe(:mail_unavailable),
    do: {"The test email could not be delivered. Check the draft mail settings", []}

  defp describe({:invalid_integer_range, key, min, max}),
    do:
      {"#{key} must be an integer between #{min} and #{max}",
       [%{path: key, message: "is outside the allowed range"}]}

  defp describe({:invalid_enum, key, values}),
    do:
      {"#{key} must be one of: #{Enum.join(values, ", ")}",
       [%{path: key, message: "is not an allowed value"}]}

  defp describe({kind, key})
       when kind in [:missing, :invalid_string, :invalid_field, :invalid_boolean],
       do: {"#{key} is invalid", [%{path: key, message: "is invalid"}]}

  defp describe(_), do: nil
end
