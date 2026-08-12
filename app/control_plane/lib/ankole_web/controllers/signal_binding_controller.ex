defmodule AnkoleWeb.SignalBindingController do
  alias OpenApiSpex, as: OpenAPISpex

  @moduledoc """
  Console REST API for operator-managed signal bindings.
  """

  use AnkoleWeb, :controller
  use OpenAPISpex.ControllerSpecs

  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.AmbientCuration
  alias Ankole.SignalsGateway.Binding
  alias AnkoleWeb.ConsoleErrors
  alias AnkoleWeb.ConsolePolicy
  alias AnkoleWeb.Schemas.ConsoleAPI.ErrorEnvelope
  alias AnkoleWeb.Schemas.ConsoleAPI.SignalAdapterListResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.SignalBindingDetailResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.SignalBindingListResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.SignalBindingResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.SignalBindingUpdateRequest
  alias AnkoleWeb.Schemas.ConsoleAPI.SignalBindingWriteRequest
  alias AnkoleWeb.Schemas.ConsoleAPI.SignalChannelStandingOrdersResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.SignalChannelStandingOrdersWriteRequest
  alias AnkoleWeb.Schemas.ConsoleAPI.SignalDeliveryRequeueRequest
  alias AnkoleWeb.Schemas.ConsoleAPI.SignalDeliveryRequeueResponse

  tags(["Signal Bindings"])
  security([%{"consoleBearer" => []}])

  plug OpenAPISpex.Plug.CastAndValidate,
    render_error: AnkoleWeb.OpenAPIValidationErrorRenderer

  operation(:adapters,
    summary: "List signal adapters available for bindings",
    responses: [
      ok: {"Signal adapters", "application/json", SignalAdapterListResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      service_unavailable: {"Adapter registry unavailable", "application/json", ErrorEnvelope}
    ]
  )

  operation(:index,
    summary: "List signal bindings for one agent",
    parameters: [
      agent_uid: [in: :path, type: :string, required: true]
    ],
    responses: [
      ok: {"Signal bindings", "application/json", SignalBindingListResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope}
    ]
  )

  operation(:show,
    summary: "Read one signal binding for editing",
    parameters: [
      agent_uid: [in: :path, type: :string, required: true],
      binding_name: [in: :path, type: :string, required: true]
    ],
    responses: [
      ok: {"Signal binding", "application/json", SignalBindingDetailResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope},
      service_unavailable: {"Adapter registry unavailable", "application/json", ErrorEnvelope}
    ]
  )

  operation(:put_binding,
    summary: "Create or update one signal binding for an agent",
    parameters: [
      agent_uid: [in: :path, type: :string, required: true],
      adapter_id: [in: :path, type: :string, required: true],
      binding_name: [in: :path, type: :string, required: true]
    ],
    request_body:
      {"Signal binding", "application/json", SignalBindingWriteRequest, required: true},
    responses: [
      ok: {"Signal binding", "application/json", SignalBindingResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Invalid value", "application/json", ErrorEnvelope},
      service_unavailable: {"Adapter registry unavailable", "application/json", ErrorEnvelope}
    ]
  )

  operation(:delete,
    summary: "Disable one signal binding for an agent",
    parameters: [
      agent_uid: [in: :path, type: :string, required: true],
      binding_name: [in: :path, type: :string, required: true]
    ],
    responses: [
      ok: {"Signal binding", "application/json", SignalBindingResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope}
    ]
  )

  operation(:update_binding,
    summary: "Edit or move one signal binding",
    parameters: [
      agent_uid: [in: :path, type: :string, required: true],
      binding_name: [in: :path, type: :string, required: true]
    ],
    request_body:
      {"Signal binding update", "application/json", SignalBindingUpdateRequest, required: true},
    responses: [
      ok: {"Signal binding", "application/json", SignalBindingResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope},
      conflict: {"Target binding conflict", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Invalid value", "application/json", ErrorEnvelope},
      service_unavailable: {"Adapter registry unavailable", "application/json", ErrorEnvelope}
    ]
  )

  operation(:requeue_delivery,
    summary: "Retry one stopped signal delivery",
    parameters: [
      agent_uid: [in: :path, type: :string, required: true]
    ],
    request_body:
      {"Stopped signal delivery", "application/json", SignalDeliveryRequeueRequest,
       required: true},
    responses: [
      ok: {"Delivery requeued", "application/json", SignalDeliveryRequeueResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope},
      conflict:
        {"Delivery is not stopped or cannot be retried", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Invalid value", "application/json", ErrorEnvelope}
    ]
  )

  operation(:show_channel_standing_orders,
    summary: "Read the standing orders of one signal channel",
    parameters: [
      channel_id: [in: :path, type: :string, required: true]
    ],
    responses: [
      ok: {"Standing orders", "application/json", SignalChannelStandingOrdersResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope}
    ]
  )

  operation(:put_channel_standing_orders,
    summary: "Replace the standing orders of one signal channel",
    parameters: [
      channel_id: [in: :path, type: :string, required: true]
    ],
    request_body:
      {"Standing orders", "application/json", SignalChannelStandingOrdersWriteRequest,
       required: true},
    responses: [
      ok: {"Standing orders", "application/json", SignalChannelStandingOrdersResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Invalid value", "application/json", ErrorEnvelope}
    ]
  )

  def adapters(conn, _params) do
    with :ok <- ConsolePolicy.authorize(conn, "signal_gateway_adapters", "read"),
         {:ok, adapters} <- SignalsGateway.list_adapters() do
      json(conn, %{signal_adapters: adapters})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def index(conn, params) do
    with {:ok, agent_uid} <- text_param(params, "agent_uid"),
         :ok <-
           ConsolePolicy.authorize(conn, "agent:#{agent_uid}:signal_gateway_bindings", "read"),
         {:ok, bindings} <- SignalsGateway.list_agent_bindings(agent_uid),
         {:ok, failures} <- SignalsGateway.list_stopped_deliveries(agent_uid) do
      json(conn, %{
        signal_bindings: Enum.map(bindings, &signal_binding_json/1),
        delivery_failures: Enum.map(failures, &signal_delivery_json/1)
      })
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def show(conn, params) do
    with {:ok, agent_uid} <- text_param(params, "agent_uid"),
         {:ok, binding_name} <- text_param(params, "binding_name"),
         :ok <-
           ConsolePolicy.authorize(conn, "agent:#{agent_uid}:signal_gateway_bindings", "update"),
         {:ok, result} <-
           SignalsGateway.get_binding_configuration(agent_uid, binding_name) do
      json(conn, %{
        signal_binding: signal_binding_json(result.binding),
        config: result.config,
        stored_secret_paths: result.stored_secret_paths
      })
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def put_binding(conn, params) do
    with {:ok, agent_uid} <- text_param(params, "agent_uid"),
         {:ok, adapter_id} <- text_param(params, "adapter_id"),
         {:ok, binding_name} <- text_param(params, "binding_name"),
         :ok <-
           ConsolePolicy.authorize(conn, "agent:#{agent_uid}:signal_gateway_bindings", "update"),
         {:ok, result} <-
           SignalsGateway.put_binding(agent_uid, adapter_id, binding_name, conn.body_params) do
      json(conn, %{signal_binding: signal_binding_json(result)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def update_binding(conn, params) do
    with {:ok, source_agent_uid} <- text_param(params, "agent_uid"),
         {:ok, target_agent_uid} <- text_param(conn.body_params, "target_agent_uid"),
         {:ok, binding_name} <- text_param(params, "binding_name"),
         :ok <- authorize_binding_update(conn, source_agent_uid, target_agent_uid),
         {:ok, result} <-
           SignalsGateway.update_binding(
             source_agent_uid,
             target_agent_uid,
             binding_name,
             conn.body_params
           ) do
      json(conn, %{signal_binding: signal_binding_json(result)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def delete(conn, params) do
    with {:ok, agent_uid} <- text_param(params, "agent_uid"),
         {:ok, binding_name} <- text_param(params, "binding_name"),
         :ok <-
           ConsolePolicy.authorize(conn, "agent:#{agent_uid}:signal_gateway_bindings", "delete"),
         {:ok, binding} <- SignalsGateway.disable_binding(agent_uid, binding_name) do
      json(conn, %{signal_binding: signal_binding_json(binding)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def requeue_delivery(conn, params) do
    with {:ok, agent_uid} <- text_param(params, "agent_uid"),
         {:ok, binding_name} <- text_param(conn.body_params, "binding_name"),
         {:ok, outbound_key} <- text_param(conn.body_params, "outbound_key"),
         :ok <-
           ConsolePolicy.authorize(conn, "agent:#{agent_uid}:signal_gateway_bindings", "update"),
         {:ok, _outbox} <-
           SignalsGateway.requeue_outbox(agent_uid, binding_name, outbound_key) do
      json(conn, %{requeued: true})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def show_channel_standing_orders(conn, params) do
    with {:ok, channel_id} <- text_param(params, "channel_id"),
         :ok <- ConsolePolicy.authorize(conn, "signal_gateway_channels", "read"),
         {:ok, standing_orders} <- AmbientCuration.channel_standing_orders(channel_id) do
      json(conn, %{standing_orders: standing_orders_json(standing_orders)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def put_channel_standing_orders(conn, params) do
    with {:ok, channel_id} <- text_param(params, "channel_id"),
         :ok <- ConsolePolicy.authorize(conn, "signal_gateway_channels", "update"),
         {:ok, orders} <- text_body_param(conn.body_params, "orders"),
         {:ok, standing_orders} <-
           AmbientCuration.put_channel_standing_orders(
             channel_id,
             orders,
             conn.assigns.current_principal_uid
           ) do
      json(conn, %{standing_orders: standing_orders_json(standing_orders)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  defp standing_orders_json(standing_orders) do
    %{
      channel_id: standing_orders.channel_id,
      channel_name: standing_orders.channel_name,
      orders: standing_orders.orders,
      set_by: standing_orders.set_by,
      updated_at: standing_orders.updated_at
    }
  end

  # Unlike text_param, an empty string is a valid value here: it clears the
  # standing orders.
  defp text_body_param(params, key) when is_map(params) do
    case Map.get(params, param_atom(key), Map.get(params, key)) do
      value when is_binary(value) -> {:ok, value}
      _value -> {:error, {:missing_param, key}}
    end
  end

  defp signal_binding_json(%{binding: %Binding{} = binding, config_key: config_key}) do
    %{
      agent_uid: binding.agent_uid,
      name: binding.name,
      adapter: binding.adapter,
      config_ref: binding.config_ref,
      config_key: config_key,
      unaddressed_group_message_policy: Atom.to_string(binding.unaddressed_group_message_policy),
      confidential_memory: binding.confidential_memory,
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
      config_key: config_key_from_ref(binding.config_ref),
      unaddressed_group_message_policy: Atom.to_string(binding.unaddressed_group_message_policy),
      confidential_memory: binding.confidential_memory,
      enabled: binding.enabled,
      unavailable_reason: binding.unavailable_reason
    }
  end

  defp signal_delivery_json(outbox) do
    %{
      binding_name: outbox.binding_name,
      outbound_key: outbox.outbound_key,
      status: Atom.to_string(outbox.status),
      state: outbox.recovery_state["state"],
      attempt_count: outbox.attempt_count,
      max_attempts: outbox.max_attempts,
      possible_duplicate: outbox.recovery_state["possible_duplicate"] == true,
      can_retry: SignalsGateway.requeueable_outbox?(outbox),
      updated_at: DateTime.to_iso8601(outbox.updated_at)
    }
  end

  defp config_key_from_ref("app-config://" <> key), do: key
  defp config_key_from_ref(config_ref) when is_binary(config_ref), do: config_ref

  defp text_param(params, key) do
    params
    |> Map.get(param_atom(key), Map.get(params, key))
    |> case do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:missing_param, key}}
          text -> {:ok, text}
        end

      _value ->
        {:error, {:missing_param, key}}
    end
  end

  defp param_atom("agent_uid"), do: :agent_uid
  defp param_atom("adapter_id"), do: :adapter_id
  defp param_atom("binding_name"), do: :binding_name
  defp param_atom("target_agent_uid"), do: :target_agent_uid
  defp param_atom("channel_id"), do: :channel_id
  defp param_atom("orders"), do: :orders
  defp param_atom("outbound_key"), do: :outbound_key

  defp authorize_binding_update(conn, agent_uid, agent_uid) do
    ConsolePolicy.authorize(conn, "agent:#{agent_uid}:signal_gateway_bindings", "update")
  end

  defp authorize_binding_update(conn, source_agent_uid, target_agent_uid) do
    with :ok <-
           ConsolePolicy.authorize(
             conn,
             "agent:#{source_agent_uid}:signal_gateway_bindings",
             "delete"
           ),
         :ok <-
           ConsolePolicy.authorize(
             conn,
             "agent:#{target_agent_uid}:signal_gateway_bindings",
             "update"
           ) do
      :ok
    end
  end

  defp error(conn, :forbidden), do: error(conn, 403, "forbidden", "access denied")
  defp error(conn, :agent_not_found), do: error(conn, 404, "not_found", "agent was not found")
  defp error(conn, :binding_not_found), do: error(conn, 404, "not_found", "binding was not found")
  defp error(conn, :outbox_not_found), do: error(conn, 404, "not_found", "delivery was not found")

  defp error(conn, reason)
       when reason in [:outbox_not_requeueable, :outbox_ambiguous_delivery_not_requeueable],
       do: error(conn, 409, "conflict", "delivery cannot be retried")

  defp error(conn, :binding_target_conflict),
    do: error(conn, 409, "conflict", "target agent already has an enabled binding with this name")

  defp error(conn, :binding_conflict),
    do: error(conn, 409, "conflict", "binding changed while it was being updated")

  defp error(conn, {:signal_adapter_not_found, _adapter_id}),
    do: error(conn, 404, "not_found", "signal adapter was not found")

  defp error(conn, :signal_adapter_registry_unavailable),
    do:
      error(
        conn,
        503,
        "service_unavailable",
        "signal adapter registry is unavailable"
      )

  defp error(conn, :missing_config),
    do: error(conn, 422, "validation_failed", "config is required")

  defp error(conn, {:missing_param, param}) do
    error(conn, 422, "validation_failed", "#{param} is required")
  end

  defp error(conn, reason) do
    error(conn, 422, "invalid_value", "signal binding configuration is invalid", [
      %{reason: inspect(reason)}
    ])
  end

  defp error(conn, status, code, message, details \\ []) do
    ConsoleErrors.render(conn, status, code, message, details)
  end
end
