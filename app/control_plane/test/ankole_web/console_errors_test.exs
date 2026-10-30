defmodule AnkoleWeb.ConsoleErrorsTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Phoenix.ConnTest, only: [json_response: 2]

  alias AnkoleWeb.ConsoleErrors

  test "render, not_found, and required_field keep the error envelope and pre-action headers" do
    conn =
      Plug.Test.conn(:get, "/")
      |> put_resp_header("x-request-id", "fallback-test")
      |> ConsoleErrors.render(403, "forbidden", "access denied")

    assert json_response(conn, 403) == %{
             "error" => %{"code" => "forbidden", "message" => "access denied", "details" => []}
           }

    assert get_resp_header(conn, "x-request-id") == ["fallback-test"]

    assert Plug.Test.conn(:get, "/")
           |> ConsoleErrors.not_found("file not found")
           |> json_response(404) == %{
             "error" => %{
               "code" => "not_found",
               "message" => "file not found",
               "details" => []
             }
           }

    assert Plug.Test.conn(:get, "/")
           |> ConsoleErrors.required_field(:path)
           |> json_response(422) == %{
             "error" => %{
               "code" => "validation_failed",
               "message" => "path is required",
               "details" => []
             }
           }
  end

  test "an unlisted reason keeps the controller code without exposing the reason" do
    secret = "private-reason-/srv/private"

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        conn =
          Plug.Test.conn(:get, "/")
          |> ConsoleErrors.unexpected(
            "test.unexpected",
            {:failed, secret},
            "invalid_probe",
            "probe failed"
          )

        assert json_response(conn, 500) == %{
                 "error" => %{
                   "code" => "invalid_probe",
                   "message" => "probe failed",
                   "details" => []
                 }
               }
      end)

    assert log =~ "console API request failed for an unhandled reason"
    refute log =~ secret
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
      body = render_validation(error)

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

    assert render_validation(error) == %{
             "error" => %{
               "code" => "validation_failed",
               "message" => "request validation failed",
               "details" => [%{"path" => "name", "message" => "must have at least 3 characters"}]
             }
           }

    unknown = Ash.Error.Unknown.exception(errors: [RuntimeError.exception(secret)])

    log =
      ExUnit.CaptureLog.capture_log([format: "$metadata $message\n", metadata: :all], fn ->
        body =
          Plug.Test.conn(:get, "/")
          |> ConsoleErrors.unexpected("test.ash.unexpected_error", unknown)
          |> json_response(500)

        assert body["error"]["code"] == "internal_error"
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

    body = render_validation(error)

    assert body["error"]["details"] == [
             %{"path" => "status", "message" => "must be one of: queued, running"},
             %{"path" => "timezone", "message" => "is not a valid timezone"},
             %{"path" => "name", "message" => "is invalid"}
           ]

    refute Ankole.JSON.encode!(body) =~ secret
    refute Ankole.Sessions.Tools.error(error).output =~ secret
  end

  test "duplicate private JSON keys stay out of validation details and tool messages" do
    secret = "private-token-/srv/private/session"

    collision = %{
      "private-token-/srv/private/session" => "string key",
      :"private-token-/srv/private/session" => "atom key"
    }

    tenant_id = "019a2b00-0000-7000-8000-000000000001"

    for {resource, action, attrs, field} <- [
          {Ankole.Schedule.Schemas.ScheduledEvent, :create_event,
           %{
             kind: "check_back_later",
             session_id: "private-key-test",
             due_at: DateTime.utc_now(),
             wake_payload: collision
           }, "wake_payload"},
          {Ankole.AIGateway.Schemas.Message, :checkpoint,
           %{
             subject_uid: "private-key-test",
             conversation_id: tenant_id,
             content: [collision]
           }, "content"}
        ] do
      changeset =
        Ankole.Repo.with_tenant(tenant_id, fn ->
          Ankole.Ash.for_create(resource, action, attrs)
        end)

      refute changeset.valid?

      for error <- [changeset, Ash.Error.to_error_class(changeset)] do
        body = render_validation(error)

        assert body["error"]["code"] == "validation_failed"

        assert %{"path" => ^field, "message" => message} =
                 Enum.find(body["error"]["details"], &(&1["path"] == field))

        assert is_binary(message) and message != ""

        refute Ankole.JSON.encode!(body) =~ secret
        result = Ankole.Sessions.Tools.error(error)
        assert result.is_error
        assert result.output =~ field
        refute result.output =~ secret
      end
    end
  end

  defp render_validation(error) do
    Plug.Test.conn(:get, "/")
    |> ConsoleErrors.render(
      422,
      "validation_failed",
      "request validation failed",
      Ankole.Ash.validation_details(error)
    )
    |> json_response(422)
  end
end
