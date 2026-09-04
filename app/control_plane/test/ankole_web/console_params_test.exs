defmodule AnkoleWeb.ConsoleParamsTest do
  use AnkoleWeb.ConnCase, async: false

  alias Ankole.Setup.Config, as: SetupConfig
  alias AnkoleWeb.ConsoleParams

  setup do
    allow_cache_database_access()
    {:ok, true} = SetupConfig.put_completed(true)
    :ok = SetupConfig.delete_bootstrap_activation_code()

    :ok
  end

  describe "CastAndValidate replaces the request parameters" do
    test "declared query parameters reach the action under atom keys with their schema types",
         %{conn: conn} do
      conn =
        conn
        |> bearer_conn()
        |> get(~p"/api/v1/ai-gateway/conversations?active=false&limit=5")

      assert json_response(conn, 200)
      assert conn.params == %{active: false, limit: 5}
    end

    test "declared path parameters reach the action cast under atom keys", %{conn: conn} do
      conn =
        conn
        |> bearer_conn()
        |> get(~p"/api/v1/background-agent-jobs/1000")

      assert json_response(conn, 404)
      assert conn.params == %{job_id: 1000}
    end

    test "declared body properties reach the action under atom keys and keep false",
         %{conn: conn} do
      conn =
        conn
        |> bearer_conn()
        |> put(~p"/api/v1/control-plane-plugins", %{"id" => "missing", "enabled" => false})

      assert json_response(conn, 404)
      assert conn.params == %{}
      assert conn.body_params == %{id: "missing", enabled: false}
    end

    test "an undeclared query parameter is rejected before the action runs", %{conn: conn} do
      conn =
        conn
        |> bearer_conn()
        |> get(~p"/api/v1/ai-gateway/conversations?bogus=1")

      assert %{"error" => %{"code" => "validation_failed"}} = json_response(conn, 422)
    end
  end

  describe "text/2" do
    test "returns the trimmed text" do
      assert ConsoleParams.text(%{name: " ops "}, :name) == {:ok, "ops"}
    end

    test "treats an empty or blank string as missing" do
      assert ConsoleParams.text(%{name: ""}, :name) == {:error, {:missing, :name}}
      assert ConsoleParams.text(%{name: "   "}, :name) == {:error, {:missing, :name}}
    end

    test "treats an absent or non-string value as missing" do
      assert ConsoleParams.text(%{}, :name) == {:error, {:missing, :name}}
      assert ConsoleParams.text(%{name: nil}, :name) == {:error, {:missing, :name}}
      assert ConsoleParams.text(%{name: 7}, :name) == {:error, {:missing, :name}}
    end
  end

  describe "optional_text/2" do
    test "returns the trimmed text, or nil for a blank or absent value" do
      assert ConsoleParams.optional_text(%{q: " x "}, :q) == "x"
      assert ConsoleParams.optional_text(%{q: ""}, :q) == nil
      assert ConsoleParams.optional_text(%{}, :q) == nil
    end
  end

  describe "boolean/3" do
    test "keeps false as a value" do
      assert ConsoleParams.boolean(%{active: false}, :active, nil) == false
      assert ConsoleParams.boolean(%{enabled: false}, :enabled, true) == false
    end

    test "returns the default when the parameter is absent" do
      assert ConsoleParams.boolean(%{}, :active, nil) == nil
      assert ConsoleParams.boolean(%{}, :enabled, true) == true
    end
  end

  describe "integer/3" do
    test "keeps zero as a value and returns the default when absent" do
      assert ConsoleParams.integer(%{limit: 0}, :limit, 50) == 0
      assert ConsoleParams.integer(%{limit: 7}, :limit, 50) == 7
      assert ConsoleParams.integer(%{}, :limit, 50) == 50
    end
  end

  describe "agent_filter_param/1" do
    test "canonicalizes the agent filter and treats a blank value as every agent" do
      assert ConsoleParams.agent_filter_param(%{agent: " Bot-1 "}) == "bot-1"
      assert ConsoleParams.agent_filter_param(%{agent: ""}) == nil
      assert ConsoleParams.agent_filter_param(%{}) == nil
    end
  end
end
