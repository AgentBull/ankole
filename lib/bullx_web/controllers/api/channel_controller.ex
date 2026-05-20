defmodule BullXWeb.Api.ChannelController do
  @moduledoc """
  CRUD for channel sources, served under `/.internal-apis/v1/channels`.

  Channels are identified by the composite `(adapter_id, id)`. Create and update
  delegate to `BullX.Setup.ChannelSources.save/2` (an upsert that validates the
  payload through the adapter, checks connectivity for enabled sources, persists,
  and reconciles the runtime).
  """

  use BullXWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias BullX.Setup.ChannelSources
  alias BullXWeb.Api.Schemas

  plug OpenApiSpex.Plug.CastAndValidate, json_render_error_v2: true

  tags ["Channels"]

  @adapter_param [in: :path, type: :string, required: true, description: "Channel adapter id."]
  @id_param [
    in: :path,
    type: :string,
    required: true,
    description: "Source id within the adapter."
  ]

  operation :index,
    operation_id: "listChannels",
    summary: "List channels",
    description: "Lists every configured channel source across all enabled adapters.",
    responses: [ok: {"Channels", "application/json", Schemas.ChannelList}]

  def index(conn, _params) do
    json(conn, %{data: ChannelSources.list()})
  end

  operation :show,
    operation_id: "getChannel",
    summary: "Get a channel",
    parameters: [adapter_id: @adapter_param, id: @id_param],
    responses: [
      ok: {"Channel", "application/json", Schemas.Channel},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]

  def show(conn, _params) do
    {adapter_id, id} = identity(conn)

    case ChannelSources.get(adapter_id, id) do
      {:ok, channel} -> json(conn, channel)
      {:error, :not_found} -> error(conn, :not_found, %{message: "channel not found"})
    end
  end

  operation :create,
    operation_id: "createChannel",
    summary: "Create a channel",
    request_body: {"Channel to create", "application/json", Schemas.ChannelCreateRequest},
    responses: [
      created: {"Created channel", "application/json", Schemas.Channel},
      unprocessable_entity: {"Validation error", "application/json", Schemas.Error}
    ]

  def create(conn, _params) do
    body = conn.body_params

    case ChannelSources.save(body.adapter_id, %{"source" => body.source}) do
      {:ok, result} ->
        respond_channel(conn, :created, body.adapter_id, result.id)

      {:error, reason} ->
        error(conn, :unprocessable_entity, reason)
    end
  end

  operation :update,
    operation_id: "updateChannel",
    summary: "Update a channel",
    parameters: [adapter_id: @adapter_param, id: @id_param],
    request_body: {"Channel changes", "application/json", Schemas.ChannelUpdateRequest},
    responses: [
      ok: {"Updated channel", "application/json", Schemas.Channel},
      not_found: {"Not found", "application/json", Schemas.Error},
      unprocessable_entity: {"Validation error", "application/json", Schemas.Error}
    ]

  def update(conn, _params) do
    {adapter_id, id} = identity(conn)
    source = Map.put(conn.body_params.source, "id", id)

    case ChannelSources.get(adapter_id, id) do
      {:error, :not_found} ->
        error(conn, :not_found, %{message: "channel not found"})

      {:ok, _channel} ->
        case ChannelSources.save(adapter_id, %{"source" => source}) do
          {:ok, _result} -> respond_channel(conn, :ok, adapter_id, id)
          {:error, reason} -> error(conn, :unprocessable_entity, reason)
        end
    end
  end

  operation :delete,
    operation_id: "deleteChannel",
    summary: "Delete a channel",
    parameters: [adapter_id: @adapter_param, id: @id_param],
    responses: [
      no_content: "Channel deleted",
      not_found: {"Not found", "application/json", Schemas.Error},
      unprocessable_entity: {"Error", "application/json", Schemas.Error}
    ]

  def delete(conn, _params) do
    {adapter_id, id} = identity(conn)

    case ChannelSources.get(adapter_id, id) do
      {:error, :not_found} ->
        error(conn, :not_found, %{message: "channel not found"})

      {:ok, _channel} ->
        case ChannelSources.delete(adapter_id, id) do
          {:ok, _result} -> send_resp(conn, :no_content, "")
          {:error, reason} -> error(conn, :unprocessable_entity, reason)
        end
    end
  end

  operation :connectivity_check,
    operation_id: "checkChannelConnectivity",
    summary: "Check channel connectivity",
    description: "Validates a source payload and probes the adapter without persisting anything.",
    request_body: {"Source to check", "application/json", Schemas.ConnectivityCheckRequest},
    responses: [
      ok: {"Connectivity result", "application/json", Schemas.ConnectivityCheckResult},
      unprocessable_entity: {"Error", "application/json", Schemas.Error}
    ]

  def connectivity_check(conn, _params) do
    body = conn.body_params

    case ChannelSources.check(body.adapter_id, %{"source" => body.source}) do
      {:ok, result} -> json(conn, %{ok: true, result: result})
      {:error, reason} -> error(conn, :unprocessable_entity, reason)
    end
  end

  defp identity(conn), do: {conn.path_params["adapter_id"], conn.path_params["id"]}

  defp respond_channel(conn, status, adapter_id, id) do
    case ChannelSources.get(adapter_id, id) do
      {:ok, channel} ->
        conn |> put_status(status) |> json(channel)

      {:error, :not_found} ->
        conn
        |> put_status(status)
        |> json(%{adapter_id: adapter_id, id: id, enabled: true, config: %{}})
    end
  end

  defp error(conn, status, reason) do
    conn |> put_status(status) |> json(normalize_error(reason))
  end

  # Guard against structs (e.g. Ecto.Changeset from a failed write): they are
  # maps but Jason can't encode them, which would turn a 422 into a 500.
  defp normalize_error(%{__struct__: _}), do: %{message: "request failed"}
  defp normalize_error(%{} = error), do: Map.put_new(error, :message, "request failed")
  defp normalize_error(other), do: %{message: inspect(other)}
end
