defmodule AnkoleWeb.ConsoleErrorsTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Phoenix.ConnTest, only: [json_response: 2]

  alias AnkoleWeb.ConsoleErrors

  defmodule CommonController do
    use Phoenix.Controller, formats: [:json]
    action_fallback ConsoleErrors

    def show(conn, _params), do: conn.assigns.result
  end

  defmodule BusinessController do
    use Phoenix.Controller, formats: [:json]
    action_fallback :fallback

    def show(conn, _params), do: conn.assigns.result

    defp fallback(conn, failure), do: ConsoleErrors.fallback(conn, failure, &error/2)

    defp error(conn, :not_found), do: ConsoleErrors.not_found(conn, "schedule was not found")

    defp error(conn, {:missing, key}),
      do: ConsoleErrors.render(conn, 422, "invalid_body", "#{key} is missing", [%{path: key}])

    defp error(conn, %Ecto.Changeset{}),
      do: ConsoleErrors.render(conn, 422, "email_taken", "another user already uses this email")

    defp error(conn, reason),
      do: ConsoleErrors.render(conn, 409, "business_conflict", "operation was refused", [reason])
  end

  test "a common failed action keeps the error envelope and pre-action response headers" do
    conn =
      Plug.Test.conn(:get, "/")
      |> put_resp_header("x-request-id", "fallback-test")
      |> assign(:result, {:error, :forbidden})
      |> CommonController.call(:show)

    assert json_response(conn, 403) == %{
             "error" => %{"code" => "forbidden", "message" => "access denied", "details" => []}
           }

    assert get_resp_header(conn, "x-request-id") == ["fallback-test"]
  end

  test "common field and changeset validation retain their messages and details" do
    missing = dispatch(CommonController, {:error, {:missing, :name}})

    assert json_response(missing, 422) == %{
             "error" => %{
               "code" => "validation_failed",
               "message" => "name is required",
               "details" => []
             }
           }

    changeset =
      {%{}, %{name: :string}}
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.add_error(:name, "must have at least %{count} characters", count: 3)

    conn = dispatch(CommonController, {:error, changeset})

    assert json_response(conn, 422) == %{
             "error" => %{
               "code" => "validation_failed",
               "message" => "request validation failed",
               "details" => [%{"path" => "name", "message" => "must have at least 3 characters"}]
             }
           }
  end

  test "business controllers share authorization and retain their validation and unknown errors" do
    assert %{"error" => %{"code" => "forbidden"}} =
             BusinessController |> dispatch({:error, :forbidden}) |> json_response(403)

    assert %{"error" => %{"message" => "schedule was not found"}} =
             BusinessController |> dispatch({:error, :not_found}) |> json_response(404)

    assert %{"error" => %{"code" => "invalid_body", "details" => [%{"path" => "body"}]}} =
             BusinessController |> dispatch({:error, {:missing, "body"}}) |> json_response(422)

    assert %{"error" => %{"code" => "email_taken"}} =
             BusinessController |> dispatch({:error, %Ecto.Changeset{}}) |> json_response(422)

    assert %{"error" => %{"code" => "business_conflict", "details" => ["changed"]}} =
             BusinessController |> dispatch({:error, "changed"}) |> json_response(409)
  end

  test "an unsupported action result fails instead of becoming a validation response" do
    assert_raise Plug.Conn.WrapperError, fn -> dispatch(CommonController, {:ok, :unexpected}) end
  end

  defp dispatch(controller, result) do
    Plug.Test.conn(:get, "/") |> assign(:result, result) |> controller.call(:show)
  end
end
