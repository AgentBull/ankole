defmodule AnkoleWeb.SignalBindingController do
  @moduledoc """
  Console REST API for operator-managed signal bindings.
  """

  use AnkoleWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.Binding
  alias AnkoleWeb.ConsolePolicy
  alias AnkoleWeb.Schemas.ConsoleApi.ErrorEnvelope
  alias AnkoleWeb.Schemas.ConsoleApi.SignalAdapterListResponse
  alias AnkoleWeb.Schemas.ConsoleApi.SignalBindingListResponse
  alias AnkoleWeb.Schemas.ConsoleApi.SignalBindingResponse
  alias AnkoleWeb.Schemas.ConsoleApi.SignalBindingWriteRequest

  tags(["Signal Bindings"])
  security([%{"consoleBearer" => []}])

  plug OpenApiSpex.Plug.CastAndValidate,
    render_error: AnkoleWeb.OpenApiValidationErrorRenderer

  operation(:adapters,
    summary: "List signal adapters available for bindings",
    responses: [
      ok: {"Signal adapters", "application/json", SignalAdapterListResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope}
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
      unprocessable_entity: {"Invalid value", "application/json", ErrorEnvelope}
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

  def adapters(conn, _params) do
    with :ok <- ConsolePolicy.authorize(conn, "signal_gateway_adapters", "read") do
      json(conn, %{data: SignalsGateway.list_adapters()})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def index(conn, params) do
    with {:ok, agent_uid} <- text_param(params, "agent_uid"),
         :ok <-
           ConsolePolicy.authorize(conn, "agent:#{agent_uid}:signal_gateway_bindings", "read"),
         {:ok, bindings} <- SignalsGateway.list_agent_bindings(agent_uid) do
      json(conn, %{data: Enum.map(bindings, &signal_binding_json/1)})
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
      json(conn, %{data: signal_binding_json(result)})
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
      json(conn, %{data: signal_binding_json(binding)})
    else
      {:error, reason} -> error(conn, reason)
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
      enabled: binding.enabled,
      unavailable_reason: binding.unavailable_reason
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

  defp error(conn, :forbidden), do: error(conn, 403, "forbidden", "access denied")
  defp error(conn, :agent_not_found), do: error(conn, 404, "not_found", "agent was not found")
  defp error(conn, :binding_not_found), do: error(conn, 404, "not_found", "binding was not found")

  defp error(conn, {:unknown_signal_adapter, _adapter_id}),
    do: error(conn, 404, "not_found", "signal adapter was not found")

  defp error(conn, :missing_config),
    do: error(conn, 422, "validation_failed", "config is required")

  defp error(conn, :missing_lark_bot_identity) do
    error(conn, 422, "validation_failed", "botOpenId or botUserId is required")
  end

  defp error(conn, {:missing_param, param}) do
    error(conn, 422, "validation_failed", "#{param} is required")
  end

  defp error(conn, reason) do
    error(conn, 422, "invalid_value", "signal binding configuration is invalid", [
      %{reason: inspect(reason)}
    ])
  end

  defp error(conn, status, code, message, details \\ []) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message, details: details}})
  end
end
