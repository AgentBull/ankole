defmodule AnkoleWeb.OpenApiValidationErrorRenderer do
  @moduledoc """
  Renders OpenAPI validation failures in the console API error envelope.
  """

  @behaviour Plug

  alias Plug.Conn

  @impl Plug
  def init(errors), do: errors

  @impl Plug
  # Reshapes OpenApiSpex's validation errors into the same `%{error: %{code,
  # message, details}}` envelope the controllers emit by hand, so clients get one
  # consistent error shape whether a request fails schema validation or business
  # logic. Always responds 422.
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
