defmodule AnkoleWeb.WorkerEnvController do
  alias OpenApiSpex, as: OpenAPISpex

  @moduledoc """
  Console REST API for Agent Computer shell environment variables.

  This is the one editing surface for both tracks: declared AppConfigure
  exports and custom operator rows. The WorkerEnv context routes each name to
  its owning track, so the console never needs to know where a variable is
  stored. Global endpoints edit the installation tier; the agent endpoints
  edit the `agent:<uid>` tier that wins per variable name.

  Every action follows the AppConfigure controller shape: authorize the
  principal for this exact resource/action via `ConsolePolicy`, call the
  context, then map domain errors onto the console error envelope.
  """

  use AnkoleWeb, :controller
  use OpenAPISpex.ControllerSpecs

  alias Ankole.SignalsGateway.ActorRuntime.WorkerEnv
  alias AnkoleWeb.ConsoleErrors
  alias AnkoleWeb.ConsolePolicy
  alias AnkoleWeb.Schemas.ConsoleAPI.ErrorEnvelope
  alias AnkoleWeb.Schemas.ConsoleAPI.WorkerEnvDecryptionResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.WorkerEnvListResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.WorkerEnvResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.WorkerEnvUpdateRequest

  tags(["WorkerEnv"])
  security([%{"consoleBearer" => []}])

  plug OpenAPISpex.Plug.CastAndValidate,
    render_error: AnkoleWeb.OpenAPIValidationErrorRenderer

  operation(:index,
    summary: "List installation-wide worker shell variables",
    responses: [
      ok: {"Worker env entries", "application/json", WorkerEnvListResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope}
    ]
  )

  operation(:show,
    summary: "Read one installation-wide worker shell variable",
    parameters: [name: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Worker env entry", "application/json", WorkerEnvResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Invalid name", "application/json", ErrorEnvelope}
    ]
  )

  operation(:update,
    summary: "Store one installation-wide worker shell variable",
    parameters: [name: [in: :path, type: :string, required: true]],
    request_body:
      {"Worker env update", "application/json", WorkerEnvUpdateRequest, required: true},
    responses: [
      ok: {"Worker env entry", "application/json", WorkerEnvResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Invalid value", "application/json", ErrorEnvelope}
    ]
  )

  operation(:delete,
    summary: "Delete one installation-wide worker shell variable",
    parameters: [name: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Worker env entry", "application/json", WorkerEnvResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Invalid name", "application/json", ErrorEnvelope}
    ]
  )

  operation(:decrypt,
    summary: "Reveal one encrypted installation-wide worker shell variable",
    parameters: [name: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Decrypted value", "application/json", WorkerEnvDecryptionResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Not encrypted", "application/json", ErrorEnvelope}
    ]
  )

  operation(:index_for_agent,
    summary: "List effective worker shell variables for one agent",
    parameters: [agent_uid: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Worker env entries", "application/json", WorkerEnvListResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Agent not found", "application/json", ErrorEnvelope}
    ]
  )

  operation(:update_for_agent,
    summary: "Store one agent-tier worker shell variable",
    parameters: [
      agent_uid: [in: :path, type: :string, required: true],
      name: [in: :path, type: :string, required: true]
    ],
    request_body:
      {"Worker env update", "application/json", WorkerEnvUpdateRequest, required: true},
    responses: [
      ok: {"Worker env entry", "application/json", WorkerEnvResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Agent not found", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Invalid value", "application/json", ErrorEnvelope}
    ]
  )

  operation(:delete_for_agent,
    summary: "Delete one agent-tier worker shell variable",
    parameters: [
      agent_uid: [in: :path, type: :string, required: true],
      name: [in: :path, type: :string, required: true]
    ],
    responses: [
      ok: {"Worker env entry", "application/json", WorkerEnvResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Invalid name", "application/json", ErrorEnvelope}
    ]
  )

  operation(:decrypt_for_agent,
    summary: "Reveal the encrypted worker shell variable effective for one agent",
    parameters: [
      agent_uid: [in: :path, type: :string, required: true],
      name: [in: :path, type: :string, required: true]
    ],
    responses: [
      ok: {"Decrypted value", "application/json", WorkerEnvDecryptionResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Not encrypted", "application/json", ErrorEnvelope}
    ]
  )

  @doc """
  Lists installation-wide variables: custom global rows plus declared exports.
  """
  def index(conn, _params) do
    with :ok <- ConsolePolicy.authorize(conn, "worker_envs", "read"),
         {:ok, items} <- WorkerEnv.console_list_global() do
      json(conn, %{worker_envs: items})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  @doc """
  Reads one installation-wide variable by name.
  """
  def show(conn, params) do
    with {:ok, name} <- name_param(params),
         :ok <- ConsolePolicy.authorize(conn, "worker_env:#{name}", "read"),
         {:ok, item} <- WorkerEnv.console_detail_global(name) do
      json(conn, %{worker_env: item})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  @doc """
  Stores one installation-wide variable, routed to its owning track.
  """
  def update(conn, params) do
    with {:ok, name} <- name_param(params),
         :ok <- ConsolePolicy.authorize(conn, "worker_env:#{name}", "update"),
         {:ok, item} <- WorkerEnv.console_put_global(name, request_attrs(conn.body_params)) do
      json(conn, %{worker_env: item})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  @doc """
  Deletes one installation-wide variable.

  A declared name falls back to its code default; a custom row disappears.
  """
  def delete(conn, params) do
    with {:ok, name} <- name_param(params),
         :ok <- ConsolePolicy.authorize(conn, "worker_env:#{name}", "reset"),
         {:ok, item} <- WorkerEnv.console_delete_global(name) do
      json(conn, %{worker_env: item})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  @doc """
  Reveals an encrypted installation-wide value on demand.

  Decryption stays a separately-authorized action so browsing configuration
  never exposes secret material by itself.
  """
  def decrypt(conn, params) do
    with {:ok, name} <- name_param(params),
         :ok <- ConsolePolicy.authorize(conn, "worker_env:#{name}", "decrypt"),
         {:ok, value} <- WorkerEnv.console_decrypt_global(name) do
      json(conn, %{decrypted_value: %{name: name, value: value}})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  @doc """
  Lists the variables effective for one agent with per-item provenance.
  """
  def index_for_agent(conn, params) do
    with {:ok, agent_uid} <- agent_uid_param(params),
         :ok <- ConsolePolicy.authorize(conn, "agent:#{agent_uid}:worker_envs", "read"),
         {:ok, items} <- WorkerEnv.console_list_for_agent(agent_uid) do
      json(conn, %{worker_envs: items})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  @doc """
  Stores one agent-tier variable, routed to its owning track.
  """
  def update_for_agent(conn, params) do
    with {:ok, agent_uid} <- agent_uid_param(params),
         {:ok, name} <- name_param(params),
         :ok <- ConsolePolicy.authorize(conn, "agent:#{agent_uid}:worker_env:#{name}", "update"),
         {:ok, item} <-
           WorkerEnv.console_put_for_agent(agent_uid, name, request_attrs(conn.body_params)) do
      json(conn, %{worker_env: item})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  @doc """
  Deletes the agent-tier value for one name; global values stay effective.
  """
  def delete_for_agent(conn, params) do
    with {:ok, agent_uid} <- agent_uid_param(params),
         {:ok, name} <- name_param(params),
         :ok <- ConsolePolicy.authorize(conn, "agent:#{agent_uid}:worker_env:#{name}", "reset"),
         {:ok, item} <- WorkerEnv.console_delete_for_agent(agent_uid, name) do
      json(conn, %{worker_env: item})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  @doc """
  Reveals the encrypted value effective for one agent on demand.
  """
  def decrypt_for_agent(conn, params) do
    with {:ok, agent_uid} <- agent_uid_param(params),
         {:ok, name} <- name_param(params),
         :ok <- ConsolePolicy.authorize(conn, "agent:#{agent_uid}:worker_env:#{name}", "decrypt"),
         {:ok, value} <- WorkerEnv.console_decrypt_for_agent(agent_uid, name) do
      json(conn, %{decrypted_value: %{name: name, value: value}})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  defp name_param(%{"name" => name}) when is_binary(name), do: {:ok, name}
  defp name_param(%{name: name}) when is_binary(name), do: {:ok, name}
  defp name_param(_params), do: {:error, :missing_name}

  defp agent_uid_param(%{"agent_uid" => agent_uid}) when is_binary(agent_uid),
    do: {:ok, agent_uid}

  defp agent_uid_param(%{agent_uid: agent_uid}) when is_binary(agent_uid), do: {:ok, agent_uid}
  defp agent_uid_param(_params), do: {:error, :missing_agent_uid}

  # The context distinguishes absent keys (keep stored state) from explicit
  # values, so only keys present in the request body are forwarded.
  defp request_attrs(body) when is_map(body) do
    Enum.reduce(["value", "secret", "description"], %{}, fn key, acc ->
      case fetch_body(body, key) do
        {:ok, value} -> Map.put(acc, key, value)
        :error -> acc
      end
    end)
  end

  defp fetch_body(body, key) do
    case Map.fetch(body, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(body, String.to_existing_atom(key))
    end
  end

  defp error(conn, :forbidden), do: error(conn, 403, "forbidden", "access denied")

  defp error(conn, :not_found) do
    error(conn, 404, "not_found", "worker env variable was not found")
  end

  defp error(conn, :agent_not_found) do
    error(conn, 404, "not_found", "agent was not found")
  end

  defp error(conn, {:invalid_worker_env_name, _name}) do
    error(conn, 422, "validation_failed", "name must match [A-Za-z_][A-Za-z0-9_]*")
  end

  defp error(conn, {:reserved_worker_env_name, name}) do
    error(conn, 422, "reserved_name", "#{name} is reserved by the worker runtime")
  end

  defp error(conn, :invalid_worker_env_value) do
    error(conn, 422, "validation_failed", "value must be a string")
  end

  defp error(conn, :invalid_worker_env_secret) do
    error(conn, 422, "validation_failed", "secret must be a boolean")
  end

  defp error(conn, :invalid_worker_env_description) do
    error(conn, 422, "validation_failed", "description must be a string or null")
  end

  defp error(conn, :not_encrypted) do
    error(conn, 422, "not_encrypted", "worker env variable is not encrypted")
  end

  defp error(conn, :missing_name) do
    error(conn, 422, "validation_failed", "name is required")
  end

  defp error(conn, :missing_agent_uid) do
    error(conn, 422, "validation_failed", "agent_uid is required")
  end

  defp error(conn, reason) do
    error(conn, 422, "invalid_value", "worker env value is invalid", [%{reason: inspect(reason)}])
  end

  defp error(conn, status, code, message, details \\ []) do
    ConsoleErrors.render(conn, status, code, message, details)
  end
end
