defmodule AnkoleWeb.OpenApiValidationErrorRenderer do
  @moduledoc """
  Renders OpenAPI validation failures in the console API error envelope.
  """

  @behaviour Plug

  alias Plug.Conn

  @impl Plug
  def init(errors), do: errors

  @impl Plug
  def call(conn, errors) do
    details =
      errors
      |> List.wrap()
      |> Enum.map(fn error ->
        %{
          "path" => OpenApiSpex.path_to_string(error),
          "message" => to_string(error)
        }
      end)

    body =
      Ankole.JSON.encode!(%{
        error: %{
          code: "validation_failed",
          message: "request validation failed",
          details: details
        }
      })

    conn
    |> Conn.put_resp_content_type("application/json")
    |> Conn.send_resp(422, body)
  end
end
