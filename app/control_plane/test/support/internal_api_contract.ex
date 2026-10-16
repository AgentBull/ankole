defmodule AnkoleWeb.InternalAPIContract do
  @moduledoc false

  def json_response(conn, status) do
    payload = Phoenix.ConnTest.json_response(conn, status)

    if String.starts_with?(conn.request_path, "/.internal-apis/") do
      route =
        Phoenix.Router.route_info(AnkoleWeb.Router, conn.method, conn.request_path, conn.host)

      operation = route.plug.open_api_operation(route.plug_opts)

      if operation do
        conn
        |> OpenApiSpex.Plug.PutApiSpec.call(AnkoleWeb.InternalAPISpec)
        |> OpenApiSpex.TestAssertions.assert_operation_response(operation.operationId)
      end
    end

    payload
  end
end
