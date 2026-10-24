defmodule Ankole.Signals.ConsoleActions do
  @moduledoc "Calls Signal Binding owners and presents their operator projections."
  use Ash.Resource.Actions.Implementation
  alias Ankole.Signals.{Binding, Bindings}
  alias Ankole.Conversations.Delivery
  alias Ankole.Errors
  @impl true
  def run(input, _opts, _context), do: input |> execute() |> Errors.wrap(&describe/1)

  @doc "Gives the AuthZ permissions required to update or move a Signal Binding."
  def update_binding_permissions(params, args, default_resource, default_action) do
    source = Map.fetch!(params, "agent_uid")
    target = Map.get(args, "target_agent_uid")

    if is_binary(target) and target != source do
      [
        {"agent:#{source}:signal_bindings", "delete"},
        {"agent:#{target}:signal_bindings", "update"}
      ]
    else
      [{default_resource, default_action}]
    end
  end

  defp execute(%{action: %{name: :console_adapters}}) do
    with {:ok, adapters} <- Bindings.list_adapters(), do: {:ok, %{signal_adapters: adapters}}
  end

  defp execute(%{action: %{name: :console_list_bindings}, arguments: attrs}) do
    agent =
      case Map.get(attrs, :agent) do
        value when value in [nil, ""] -> nil
        value -> value
      end

    with {:ok, bindings} <- Bindings.list_bindings(agent),
         {:ok, failures} <- Delivery.list_stopped_deliveries(agent) do
      {:ok,
       %{
         signal_bindings: Enum.map(bindings, &signal_binding_json/1),
         delivery_failures: Enum.map(failures, &signal_delivery_json/1)
       }}
    end
  end

  defp execute(%{action: %{name: :console_get_binding}, arguments: attrs}) do
    with {:ok, result} <- Bindings.get_binding_configuration(attrs.agent_uid, attrs.binding_name) do
      {:ok,
       %{
         signal_binding: signal_binding_json(result.binding),
         config: result.config,
         stored_secret_paths: result.stored_secret_paths
       }}
    end
  end

  defp execute(%{action: %{name: :console_put_binding}, arguments: attrs}) do
    with {:ok, result} <-
           Bindings.put_binding(
             attrs.agent_uid,
             attrs.adapter_id,
             attrs.binding_name,
             binding_attrs(attrs)
           ),
         do: {:ok, %{signal_binding: signal_binding_json(result)}}
  end

  defp execute(%{action: %{name: :console_update_binding}, arguments: attrs}) do
    with {:ok, result} <-
           Bindings.update_binding(
             attrs.agent_uid,
             attrs.target_agent_uid,
             attrs.binding_name,
             binding_attrs(attrs)
           ),
         do: {:ok, %{signal_binding: signal_binding_json(result)}}
  end

  defp execute(%{action: %{name: :console_requeue}, arguments: attrs}) do
    with {:ok, _} <- Delivery.requeue(attrs.agent_uid, attrs.binding_name, attrs.outbound_key),
         do: {:ok, %{requeued: true}}
  end

  defp binding_attrs(attrs),
    do:
      attrs
      |> Map.take([:config, :target, :filters, :group_message_mode, :unmatched_sender_policy])
      |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)

  defp signal_binding_json(%{binding: %Binding{} = binding, config_key: config_key}) do
    %{
      agent_uid: binding.agent_uid,
      name: binding.name,
      adapter: binding.adapter,
      config_ref: binding.config_ref,
      target: binding.target,
      filters: binding.filters,
      config_key: config_key,
      unaddressed_group_message_policy: Atom.to_string(binding.unaddressed_group_message_policy),
      unmatched_sender_policy: Atom.to_string(binding.unmatched_sender_policy),
      enabled: binding.enabled,
      unavailable_reason: binding.unavailable_reason
    }
  end

  defp signal_binding_json(%Binding{} = binding) do
    %{
      agent_uid: binding.agent_uid,
      name: binding.name,
      adapter: binding.adapter,
      config_ref: binding.config_ref,
      target: binding.target,
      filters: binding.filters,
      config_key: config_key_from_ref(binding.config_ref),
      unaddressed_group_message_policy: Atom.to_string(binding.unaddressed_group_message_policy),
      unmatched_sender_policy: Atom.to_string(binding.unmatched_sender_policy),
      enabled: binding.enabled,
      unavailable_reason: binding.unavailable_reason
    }
  end

  defp delivery_state(%{recovery_status: nil}), do: nil
  defp delivery_state(intent), do: Atom.to_string(intent.recovery_status)

  defp signal_delivery_json(intent) do
    %{
      agent_uid: intent.agent_uid,
      binding_name: intent.binding_name,
      outbound_key: intent.outbound_key,
      status: Atom.to_string(intent.status),
      state: delivery_state(intent),
      attempt_count: intent.attempt_count,
      max_attempts: intent.max_attempts,
      possible_duplicate: intent.possible_duplicate,
      can_retry: Ankole.Conversations.Delivery.requeueable?(intent),
      updated_at: DateTime.to_iso8601(intent.updated_at)
    }
  end

  defp config_key_from_ref("app-config://" <> key), do: key
  defp config_key_from_ref(config_ref) when is_binary(config_ref), do: config_ref

  defp describe(reason) when reason in [:agent_not_found, :binding_not_found, :intent_not_found],
    do: Errors.Invalid.NotFound.exception(resource: Binding)

  defp describe({:signal_adapter_not_found, _}),
    do: Errors.Invalid.NotFound.exception(resource: Ankole.Signals.Adapters)

  defp describe({:platform_application_identity_unavailable, reference}),
    do:
      {"Could not verify an existing platform application; repair its credentials before retrying",
       [reference]}

  defp describe(:platform_application_identity_unavailable),
    do:
      {"Could not verify the platform application; check the bot credentials and provider availability",
       []}

  defp describe(:platform_app_bound_to_another_tenant),
    do: {:conflict, "This platform application belongs to another tenant", []}

  defp describe(reason)
       when reason in [:intent_not_requeueable, :intent_ambiguous_delivery_not_requeueable],
       do: {:conflict, "This delivery cannot be retried", []}

  defp describe(:binding_target_conflict),
    do: {:conflict, "The target Agent already has an enabled binding with this name", []}

  defp describe(:binding_conflict),
    do: {:conflict, "The binding changed while it was being updated; reload it and try again", []}

  defp describe(:signal_adapter_registry_unavailable),
    do: {"The Signal adapter registry is unavailable; retry when it is ready", []}

  defp describe(:missing_config),
    do: {"Configuration is required", [%{path: "config", message: "is required"}]}

  defp describe({:invalid_enum, key, values}),
    do:
      {"#{key} must be one of: #{Enum.join(values, ", ")}",
       [%{path: to_string(key), message: "is not an allowed value"}]}

  defp describe({:missing, key}),
    do: {"#{key} is required", [%{path: to_string(key), kind: "missing"}]}

  defp describe({kind, key}) when kind in [:invalid_string, :invalid_field, :invalid_boolean],
    do: {"#{key} is invalid", [%{path: to_string(key), kind: "invalid"}]}

  defp describe({:unknown_group_message_mode, _}),
    do:
      {"Choose a supported group message mode",
       [%{path: "group_message_mode", message: "is not supported"}]}

  defp describe(_), do: nil
end
