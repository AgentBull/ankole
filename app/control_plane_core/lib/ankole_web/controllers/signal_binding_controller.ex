defmodule AnkoleWeb.SignalBindingController do
  alias OpenApiSpex, as: OpenAPISpex

  @moduledoc """
  Console REST API for operator-managed signal bindings.
  """

  use AnkoleWeb, :controller

  action_fallback :fallback
  use OpenAPISpex.ControllerSpecs

  alias Ankole.Sessions.AmbientCuration
  alias Ankole.Signals.Binding
  alias AnkoleWeb.ConsoleErrors
  alias AnkoleWeb.ConsoleParams
  alias AnkoleWeb.ConsolePolicy
  alias AnkoleWeb.Schemas.ConsoleAPI.ErrorEnvelope
  alias AnkoleWeb.Schemas.ConsoleAPI.SignalAdapterListResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.SignalBindingDetailResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.SignalBindingListResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.SignalBindingResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.SignalBindingUpdateRequest
  alias AnkoleWeb.Schemas.ConsoleAPI.SignalBindingWriteRequest
  alias AnkoleWeb.Schemas.ConsoleAPI.ConversationStandingOrdersResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.ConversationStandingOrdersWriteRequest
  alias AnkoleWeb.Schemas.ConsoleAPI.SignalDeliveryRequeueRequest
  alias AnkoleWeb.Schemas.ConsoleAPI.SignalDeliveryRequeueResponse

  tags(["Signal Bindings"])
  security([%{"consoleSession" => []}])

  plug(OpenAPISpex.Plug.CastAndValidate,
    render_error: AnkoleWeb.OpenAPIValidationErrorRenderer
  )

  operation(:adapters,
    summary: "List signal adapters available for bindings",
    responses: [
      ok: {"Signal adapters", "application/json", SignalAdapterListResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  operation(:index,
    summary: "List signal bindings",
    parameters: [
      agent: [in: :query, type: :string, required: false]
    ],
    responses: [
      ok: {"Signal bindings", "application/json", SignalBindingListResponse},
      default: {"Error", "application/json", ErrorEnvelope}
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
      default: {"Error", "application/json", ErrorEnvelope}
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
      default: {"Error", "application/json", ErrorEnvelope}
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
      default: {"Error", "application/json", ErrorEnvelope}
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
      default: {"Error", "application/json", ErrorEnvelope}
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
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  operation(:show_conversation_standing_orders,
    summary: "Read the standing orders of one conversation",
    parameters: [
      conversation_id: [
        in: :path,
        type: %OpenAPISpex.Schema{type: :string, format: :uuid},
        required: true
      ]
    ],
    responses: [
      ok: {"Standing orders", "application/json", ConversationStandingOrdersResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  operation(:put_conversation_standing_orders,
    summary: "Replace the standing orders of one conversation",
    parameters: [
      conversation_id: [
        in: :path,
        type: %OpenAPISpex.Schema{type: :string, format: :uuid},
        required: true
      ]
    ],
    request_body:
      {"Standing orders", "application/json", ConversationStandingOrdersWriteRequest,
       required: true},
    responses: [
      ok: {"Standing orders", "application/json", ConversationStandingOrdersResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  def adapters(conn, _params) do
    with :ok <- ConsolePolicy.authorize(conn, "signals_adapters", "read"),
         {:ok, adapters} <- Ankole.Signals.Bindings.list_adapters() do
      json(conn, %{signal_adapters: adapters})
    end
  end

  def index(conn, params) do
    with :ok <- ConsolePolicy.authorize(conn, "signal_bindings", "read"),
         agent_uid = ConsoleParams.agent_filter_param(params),
         {:ok, bindings} <- Ankole.Signals.Bindings.list_bindings(agent_uid),
         {:ok, failures} <- Ankole.Conversations.Delivery.list_stopped_deliveries(agent_uid) do
      json(conn, %{
        signal_bindings: Enum.map(bindings, &signal_binding_json/1),
        delivery_failures: Enum.map(failures, &signal_delivery_json/1)
      })
    end
  end

  def show(conn, params) do
    with {:ok, agent_uid} <- ConsoleParams.text(params, :agent_uid),
         {:ok, binding_name} <- ConsoleParams.text(params, :binding_name),
         :ok <-
           ConsolePolicy.authorize(conn, "agent:#{agent_uid}:signal_bindings", "update"),
         {:ok, result} <-
           Ankole.Signals.Bindings.get_binding_configuration(agent_uid, binding_name) do
      json(conn, %{
        signal_binding: signal_binding_json(result.binding),
        config: result.config,
        stored_secret_paths: result.stored_secret_paths
      })
    end
  end

  def put_binding(conn, params) do
    with {:ok, agent_uid} <- ConsoleParams.text(params, :agent_uid),
         {:ok, adapter_id} <- ConsoleParams.text(params, :adapter_id),
         {:ok, binding_name} <- ConsoleParams.text(params, :binding_name),
         :ok <-
           ConsolePolicy.authorize(conn, "agent:#{agent_uid}:signal_bindings", "update"),
         {:ok, result} <-
           Ankole.Signals.Bindings.put_binding(
             agent_uid,
             adapter_id,
             binding_name,
             conn.body_params
           ) do
      json(conn, %{signal_binding: signal_binding_json(result)})
    end
  end

  def update_binding(conn, params) do
    with {:ok, source_agent_uid} <- ConsoleParams.text(params, :agent_uid),
         {:ok, target_agent_uid} <- ConsoleParams.text(conn.body_params, :target_agent_uid),
         {:ok, binding_name} <- ConsoleParams.text(params, :binding_name),
         :ok <- authorize_binding_update(conn, source_agent_uid, target_agent_uid),
         {:ok, result} <-
           Ankole.Signals.Bindings.update_binding(
             source_agent_uid,
             target_agent_uid,
             binding_name,
             conn.body_params
           ) do
      json(conn, %{signal_binding: signal_binding_json(result)})
    end
  end

  def delete(conn, params) do
    with {:ok, agent_uid} <- ConsoleParams.text(params, :agent_uid),
         {:ok, binding_name} <- ConsoleParams.text(params, :binding_name),
         :ok <-
           ConsolePolicy.authorize(conn, "agent:#{agent_uid}:signal_bindings", "delete"),
         {:ok, binding} <- Ankole.Signals.Bindings.disable_binding(agent_uid, binding_name) do
      json(conn, %{signal_binding: signal_binding_json(binding)})
    end
  end

  def requeue_delivery(conn, params) do
    with {:ok, agent_uid} <- ConsoleParams.text(params, :agent_uid),
         {:ok, binding_name} <- ConsoleParams.text(conn.body_params, :binding_name),
         {:ok, outbound_key} <- ConsoleParams.text(conn.body_params, :outbound_key),
         :ok <-
           ConsolePolicy.authorize(conn, "agent:#{agent_uid}:signal_bindings", "update"),
         {:ok, _intent} <-
           Ankole.Conversations.Delivery.requeue(agent_uid, binding_name, outbound_key) do
      json(conn, %{requeued: true})
    end
  end

  def show_conversation_standing_orders(conn, params) do
    with {:ok, conversation_id} <- ConsoleParams.text(params, :conversation_id),
         :ok <- ConsolePolicy.authorize(conn, "conversations", "read"),
         {:ok, standing_orders} <- AmbientCuration.conversation_standing_orders(conversation_id) do
      json(conn, %{standing_orders: standing_orders_json(standing_orders)})
    end
  end

  # An empty `orders` string is a valid value: it clears the standing orders.
  def put_conversation_standing_orders(conn, params) do
    with {:ok, conversation_id} <- ConsoleParams.text(params, :conversation_id),
         :ok <- ConsolePolicy.authorize(conn, "conversations", "update"),
         {:ok, standing_orders} <-
           AmbientCuration.put_conversation_standing_orders(
             conversation_id,
             conn.body_params.orders,
             to_string(Ankole.ActorRef.from_principal(conn.assigns.current_principal))
           ) do
      json(conn, %{standing_orders: standing_orders_json(standing_orders)})
    end
  end

  defp standing_orders_json(standing_orders) do
    %{
      conversation_id: standing_orders.conversation_id,
      title: standing_orders.title,
      orders: standing_orders.orders,
      set_by: standing_orders.set_by,
      updated_at: Ankole.JSON.plain(standing_orders.updated_at)
    }
  end

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

  defp authorize_binding_update(conn, agent_uid, agent_uid) do
    ConsolePolicy.authorize(conn, "agent:#{agent_uid}:signal_bindings", "update")
  end

  defp authorize_binding_update(conn, source_agent_uid, target_agent_uid) do
    with :ok <-
           ConsolePolicy.authorize(
             conn,
             "agent:#{source_agent_uid}:signal_bindings",
             "delete"
           ),
         :ok <-
           ConsolePolicy.authorize(
             conn,
             "agent:#{target_agent_uid}:signal_bindings",
             "update"
           ) do
      :ok
    end
  end

  defp fallback(conn, failure),
    do:
      ConsoleErrors.fallback(conn, failure, &error/2,
        validation: {"invalid_value", "signal binding configuration is invalid"}
      )

  defp error(conn, {:platform_application_identity_unavailable, reference}),
    do:
      ConsoleErrors.render(
        conn,
        422,
        "platform_application_identity_unavailable",
        "Could not verify an existing platform application; repair the referenced credentials before retrying",
        [reference]
      )

  defp error(conn, :platform_application_identity_unavailable),
    do:
      ConsoleErrors.render(
        conn,
        422,
        "platform_application_identity_unavailable",
        "Could not verify the platform application; check the bot credentials and provider availability"
      )

  defp error(conn, :platform_app_bound_to_another_tenant),
    do:
      ConsoleErrors.render(
        conn,
        409,
        "platform_app_bound_to_another_tenant",
        "This platform application belongs to another tenant"
      )

  defp error(conn, :agent_not_found), do: ConsoleErrors.not_found(conn, "agent was not found")
  defp error(conn, :binding_not_found), do: ConsoleErrors.not_found(conn, "binding was not found")
  defp error(conn, :intent_not_found), do: ConsoleErrors.not_found(conn, "delivery was not found")

  defp error(conn, reason)
       when reason in [:intent_not_requeueable, :intent_ambiguous_delivery_not_requeueable],
       do: ConsoleErrors.render(conn, 409, "conflict", "delivery cannot be retried")

  defp error(conn, :binding_target_conflict),
    do:
      ConsoleErrors.render(
        conn,
        409,
        "conflict",
        "target agent already has an enabled binding with this name"
      )

  defp error(conn, :binding_conflict),
    do: ConsoleErrors.render(conn, 409, "conflict", "binding changed while it was being updated")

  defp error(conn, {:signal_adapter_not_found, _adapter_id}),
    do: ConsoleErrors.not_found(conn, "signal adapter was not found")

  defp error(conn, :signal_adapter_registry_unavailable),
    do:
      ConsoleErrors.render(
        conn,
        503,
        "service_unavailable",
        "signal adapter registry is unavailable"
      )

  defp error(conn, :missing_config),
    do: ConsoleErrors.render(conn, 422, "validation_failed", "config is required")

  # An atom key names a request parameter. A string key names a binding config
  # field, which the fallback clause renders with its field path.
  defp error(conn, {:missing, key}) when is_atom(key) do
    ConsoleErrors.required_field(conn, key)
  end

  defp error(conn, reason) do
    with :unhandled <- ConsoleErrors.render_config_field_error(conn, reason) do
      ConsoleErrors.unexpected(
        conn,
        "signals.binding_api.unexpected_error",
        reason,
        "invalid_value",
        "signal binding configuration is invalid"
      )
    end
  end
end
