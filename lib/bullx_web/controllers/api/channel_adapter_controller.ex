defmodule BullXWeb.Api.ChannelAdapterController do
  @moduledoc """
  Lists available channel adapters and their config `form_schema`.

  The console uses each adapter's `form_schema` to render the create/edit forms,
  so the per-adapter field shapes never have to be hard-coded on the client.
  """

  use BullXWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias BullX.Setup.ChannelSources
  alias BullXWeb.Api.Schemas

  plug OpenApiSpex.Plug.CastAndValidate, json_render_error_v2: true

  tags ["Channels"]

  operation :index,
    operation_id: "listChannelAdapters",
    summary: "List channel adapters",
    description: "Lists installed channel adapters and the schema describing their config form.",
    responses: [ok: {"Adapters", "application/json", Schemas.ChannelAdapterList}]

  def index(conn, _params) do
    json(conn, %{
      data: Enum.map(ChannelSources.public_projection(), &adapter_view/1),
      oidc_callback_url_template: url(~p"/sessions/oidc/__source_id__/callback")
    })
  end

  defp adapter_view(adapter) do
    %{
      id: adapter.id,
      plugin_id: adapter.plugin_id,
      label: label(adapter),
      form_schema: adapter.form_schema
    }
  end

  defp label(adapter) do
    Map.get(adapter.form_schema, :label) || Map.get(adapter.form_schema, "label") || adapter.id
  end
end
