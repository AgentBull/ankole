defmodule AnkoleWeb.ConsoleParamsTest do
  use AnkoleWeb.ConnCase, async: false

  alias Ankole.Setup.Config, as: SetupConfig

  setup do
    {:ok, true} = Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), true)
    :ok = SetupConfig.delete_bootstrap_activation_code()

    :ok
  end

  describe "CastAndValidate replaces the request parameters" do
    test "declared query parameters reach the action under atom keys with their schema types",
         %{conn: conn} do
      conn =
        conn
        |> console_conn()
        |> get(~p"/api/v1/ai-gateway/conversations?active=false&limit=5")

      assert json_response(conn, 200)
      assert conn.params == %{active: false, limit: 5}
    end

    test "declared path parameters reach the action cast under atom keys", %{conn: conn} do
      conn =
        conn
        |> console_conn()
        |> get(~p"/api/v1/background-agent-jobs/1000")

      assert json_response(conn, 404)
      assert conn.params == %{job_id: 1000}
    end

    test "declared body properties reach the action under atom keys and keep false",
         %{conn: conn} do
      conn =
        conn
        |> console_conn()
        |> put(~p"/api/v1/site/control-plane-plugins", %{"id" => "missing", "enabled" => false})

      assert json_response(conn, 404)
      assert conn.params == %{}
      assert conn.body_params == %{id: "missing", enabled: false}
    end

    test "an undeclared query parameter is rejected before the action runs", %{conn: conn} do
      conn =
        conn
        |> console_conn()
        |> get(~p"/api/v1/ai-gateway/conversations?bogus=1")

      assert %{"error" => %{"code" => "validation_failed"}} = json_response(conn, 422)
    end
  end
end
