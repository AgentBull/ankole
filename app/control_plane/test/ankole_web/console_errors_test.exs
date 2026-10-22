defmodule AnkoleWeb.ConsoleErrorsTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Phoenix.ConnTest, only: [json_response: 2]

  alias AnkoleWeb.ConsoleErrors

  defmodule CommonController do
    use Phoenix.Controller, formats: [:json]
    action_fallback(ConsoleErrors)

    def show(conn, _params), do: conn.assigns.result
  end

  defmodule BusinessController do
    use Phoenix.Controller, formats: [:json]
    action_fallback(:fallback)

    def show(conn, _params), do: conn.assigns.result

    defp fallback(conn, failure), do: ConsoleErrors.fallback(conn, failure, &error/2)

    defp error(conn, :not_found), do: ConsoleErrors.not_found(conn, "schedule was not found")

    defp error(conn, {:missing, key}),
      do: ConsoleErrors.render(conn, 422, "invalid_body", "#{key} is missing", [%{path: key}])

    defp error(conn, %Ash.Error.Invalid{
           errors: [%Ash.Error.Changes.InvalidAttribute{field: :email}]
         }),
         do:
           ConsoleErrors.render(conn, 422, "email_taken", "another user already uses this email")

    defp error(conn, %module{} = error) when module in [Ash.Changeset, Ash.Error.Invalid],
      do: ConsoleErrors.changeset(conn, error)

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
      Ash.Error.Invalid.exception(
        errors: [
          Ash.Error.Changes.InvalidAttribute.exception(
            field: :name,
            message: "must have at least %{count} characters",
            vars: [count: 3]
          )
        ]
      )

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

    email_taken =
      Ash.Error.Invalid.exception(
        errors: [
          Ash.Error.Changes.InvalidAttribute.exception(field: :email, message: "has been taken")
        ]
      )

    assert %{"error" => %{"code" => "email_taken"}} =
             BusinessController |> dispatch({:error, email_taken}) |> json_response(422)

    assert %{"error" => %{"code" => "business_conflict", "details" => ["changed"]}} =
             BusinessController |> dispatch({:error, "changed"}) |> json_response(409)
  end

  test "Ash validation stays field scoped without exposing private action input" do
    secret = "private-token-and-path-/srv/private/session"
    tenant_id = "019a2b00-0000-7000-8000-000000000001"

    changeset =
      Ankole.Repo.with_tenant(tenant_id, fn ->
        Ash.Changeset.for_create(
          Ankole.Schedule.Schemas.ScheduledEvent,
          :create_event,
          %{kind: "check_back_later", session_id: secret, wake_payload: %{"token" => secret}},
          tenant: tenant_id,
          authorize?: false
        )
      end)

    refute changeset.valid?

    for error <- [changeset, Ash.Error.to_error_class(changeset)] do
      body = BusinessController |> dispatch({:error, error}) |> json_response(422)

      assert body["error"]["code"] == "validation_failed"

      assert %{"path" => "due_at", "message" => "is required"} in body["error"]["details"]
      refute Ankole.JSON.encode!(body) =~ secret

      result = Ankole.Sessions.Tools.error(error)
      assert result.is_error
      assert result.output =~ "due_at"
      refute result.output =~ secret
      refute result.output =~ "Ash.Changeset"
    end
  end

  test "Ash messages expose declared validation limits without private values" do
    secret = "private-token-/srv/private/session"

    error =
      Ash.Error.Invalid.exception(
        errors: [
          Ash.Error.Changes.InvalidAttribute.exception(
            field: :name,
            message: "must have at least %{count} characters",
            vars: [count: 3, token: secret],
            private_vars: [constraint: secret],
            value: %{token: secret},
            path: [secret]
          )
        ],
        path: [secret]
      )

    assert BusinessController |> dispatch({:error, error}) |> json_response(422) == %{
             "error" => %{
               "code" => "validation_failed",
               "message" => "request validation failed",
               "details" => [%{"path" => "name", "message" => "must have at least 3 characters"}]
             }
           }

    unknown = Ash.Error.Unknown.exception(errors: [RuntimeError.exception(secret)])

    log =
      ExUnit.CaptureLog.capture_log([format: "$metadata $message\n", metadata: :all], fn ->
        body = BusinessController |> dispatch({:error, unknown}) |> json_response(422)
        assert body["error"]["code"] == "invalid_value"
        refute Ankole.JSON.encode!(body) =~ secret
        refute Ankole.Sessions.Tools.error(unknown).output =~ secret
      end)

    assert log =~ "Ash.Error.Unknown"
    refute log =~ secret
  end

  test "public validation shows allowed values and omits parser input and unknown template values" do
    secret = "private-token-/srv/private/session"
    changeset = struct(Ash.Changeset, attributes: %{timezone: secret})
    assert {:error, timezone} = Ankole.TimeZone.validate(changeset, [], %{})

    error =
      Ash.Error.Invalid.exception(
        errors: [
          Ash.Error.Changes.InvalidAttribute.exception(
            field: :status,
            message: "must be in %{list}",
            vars: [list: [:queued, :running]],
            value: secret
          ),
          Ash.Error.Changes.InvalidAttribute.exception(timezone),
          Ash.Error.Changes.InvalidAttribute.exception(
            field: :name,
            message: "cannot use %{input}",
            vars: [input: secret]
          )
        ]
      )

    body = BusinessController |> dispatch({:error, error}) |> json_response(422)

    assert body["error"]["details"] == [
             %{"path" => "status", "message" => "must be one of: queued, running"},
             %{"path" => "timezone", "message" => "is not a valid timezone"},
             %{"path" => "name", "message" => "is invalid"}
           ]

    refute Ankole.JSON.encode!(body) =~ secret
    refute Ankole.Sessions.Tools.error(error).output =~ secret
  end

  test "duplicate private JSON keys stay out of Console and tool validation messages" do
    secret = "private-token-/srv/private/session"

    collision = %{
      "private-token-/srv/private/session" => "string key",
      :"private-token-/srv/private/session" => "atom key"
    }

    tenant_id = "019a2b00-0000-7000-8000-000000000001"

    for {resource, action, attrs, field, kind} <- [
          {Ankole.Schedule.Schemas.ScheduledEvent, :create_event,
           %{
             kind: "check_back_later",
             session_id: "private-key-test",
             due_at: DateTime.utc_now(),
             wake_payload: collision
           }, "wake_payload", "object"},
          {Ankole.AIGateway.Schemas.Message, :checkpoint,
           %{
             subject_uid: "private-key-test",
             conversation_id: tenant_id,
             content: [collision]
           }, "content", "list"}
        ] do
      changeset =
        Ankole.Repo.with_tenant(tenant_id, fn ->
          Ankole.Ash.for_create(resource, action, attrs)
        end)

      refute changeset.valid?

      for error <- [changeset, Ash.Error.to_error_class(changeset)] do
        body = BusinessController |> dispatch({:error, error}) |> json_response(422)

        assert body["error"]["code"] == "validation_failed"

        assert %{
                 "path" => field,
                 "message" => "must be JSON-serializable #{kind}: duplicate normalized key"
               } in body["error"]["details"]

        refute Ankole.JSON.encode!(body) =~ secret
        result = Ankole.Sessions.Tools.error(error)
        assert result.is_error
        assert result.output =~ field
        refute result.output =~ secret
      end
    end
  end

  test "an unsupported action result fails instead of becoming a validation response" do
    assert_raise Plug.Conn.WrapperError, fn -> dispatch(CommonController, {:ok, :unexpected}) end
  end

  defp dispatch(controller, result) do
    Plug.Test.conn(:get, "/") |> assign(:result, result) |> controller.call(:show)
  end
end
