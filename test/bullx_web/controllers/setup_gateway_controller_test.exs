defmodule BullXWeb.SetupGatewayControllerTest do
  use BullXWeb.ConnCase, async: false

  alias BullX.Config.AppConfig
  alias BullX.Config.Accounts, as: AccountsConfig
  alias BullXGateway.{AdapterConfig, AdapterSupervisor}
  alias BullXAccounts.ActivationCode

  @config_key "bullx.gateway.adapters"
  @match_rules_key "bullx.accounts.authn_match_rules"
  @token_salt "setup_gateway_adapter_connectivity"

  setup do
    previous_config = Repo.get(AppConfig, @config_key)
    previous_match_rules = Repo.get(AppConfig, @match_rules_key)

    on_exit(fn ->
      AdapterSupervisor.stop_channel({:feishu, "ops-main"})

      case previous_config do
        nil -> BullX.Config.delete(@config_key)
        %AppConfig{value: value} -> BullX.Config.put(@config_key, value)
      end

      case previous_match_rules do
        nil -> BullX.Config.delete(@match_rules_key)
        %AppConfig{value: value} -> BullX.Config.put(@match_rules_key, value)
      end

      AdapterSupervisor.reconcile_configured_channels(BullX.Config.Gateway.adapters())
    end)

    :ok
  end

  test "GET /setup/gateway renders setup SPA with adapter catalog", %{conn: conn} do
    conn =
      conn
      |> setup_session()
      |> get(~p"/setup/gateway")

    response = html_response(conn, 200)

    assert response =~ "setup/App"
    assert response =~ "adapter_catalog"
    assert response =~ "back_path"
    assert response =~ "/setup/llm"
    assert response =~ "generated_secret_path"
    assert response =~ "web_login_callback_origin"
    assert response =~ BullXWeb.Endpoint.url()
  end

  test "POST /setup/gateway/adapters/check requires the setup session", %{conn: conn} do
    Repo.delete_all(ActivationCode)
    {:ok, _result} = BullXAccounts.create_or_refresh_bootstrap_activation_code()

    conn = post(conn, ~p"/setup/gateway/adapters/check", %{"adapter" => feishu_entry()})

    assert json_response(conn, 401)["redirect_to"] == ~p"/setup/sessions/new"
  end

  test "POST /setup/gateway/adapters/check validates adapter payload before connectivity", %{
    conn: conn
  } do
    conn =
      conn
      |> setup_session()
      |> post(~p"/setup/gateway/adapters/check", %{
        "adapter" => feishu_entry(%{"credentials" => %{"app_id" => "", "app_secret" => ""}})
      })

    response = json_response(conn, 422)

    assert response["ok"] == false
    assert [%{"kind" => "config"} | _] = response["errors"]
  end

  test "POST /setup/gateway/adapters rejects save without fresh connectivity token", %{conn: conn} do
    conn =
      conn
      |> setup_session()
      |> post(~p"/setup/gateway/adapters", %{"adapters" => [feishu_entry()]})

    response = json_response(conn, 422)

    assert response["ok"] == false
    assert [%{"kind" => "connectivity"}] = response["errors"]
    refute Repo.get(AppConfig, @config_key)
  end

  test "POST /setup/gateway/adapters/generated-secret creates supported generated secrets", %{
    conn: conn
  } do
    conn =
      conn
      |> setup_session()
      |> post(~p"/setup/gateway/adapters/generated-secret", %{
        "adapter" => "telegram",
        "path" => ["transport", "secret_token"]
      })

    response = json_response(conn, 200)

    assert response["ok"] == true
    assert {:ok, _secret} = BullX.Config.GeneratedSecret.cast(response["value"])
  end

  test "POST /setup/gateway/adapters/generated-secret rejects unsupported fields", %{conn: conn} do
    conn =
      conn
      |> setup_session()
      |> post(~p"/setup/gateway/adapters/generated-secret", %{
        "adapter" => "telegram",
        "path" => ["credentials", "bot_token"]
      })

    response = json_response(conn, 422)

    assert response["ok"] == false
    assert [%{"kind" => "config"}] = response["errors"]
  end

  test "POST /setup/gateway/adapters persists JSON and refreshes runtime config with a valid token",
       %{conn: conn} do
    conn = setup_session(conn)
    entry = feishu_entry()
    {:ok, normalized} = AdapterConfig.normalize_entry(entry)

    token =
      Phoenix.Token.sign(BullXWeb.Endpoint, @token_salt, %{
        "adapter" => normalized["adapter"],
        "channel_id" => normalized["channel_id"],
        "fingerprint" => AdapterConfig.fingerprint(normalized)
      })

    conn =
      post(conn, ~p"/setup/gateway/adapters", %{
        "adapters" => [entry],
        "connectivity_tokens" => %{normalized["id"] => token}
      })

    response = json_response(conn, 200)

    assert response["ok"] == true
    assert response["redirect_to"] == ~p"/setup/activate-owner"
    assert %AppConfig{type: :secret} = Repo.get(AppConfig, @config_key)
    assert {:ok, raw} = BullX.Config.Cache.get_raw(@config_key)

    assert {:ok, [{{:feishu, "ops-main"}, BullXFeishu.Adapter, config}]} =
             AdapterConfig.cast(raw)

    assert config.app_secret == "secret_test"
    refute Map.has_key?(config, :authn)

    assert BullX.Config.Gateway.adapters() == [
             {{:feishu, "ops-main"}, BullXFeishu.Adapter, config}
           ]

    assert is_pid(AdapterSupervisor.whereis_channel({:feishu, "ops-main"}))

    assert %AppConfig{value: match_rules_raw} = Repo.get(AppConfig, @match_rules_key)

    assert {:ok,
            [
              %{
                "managed_by" => "setup.gateway.external_org_members",
                "op" => "equals_any",
                "result" => "allow_create_user",
                "source_path" => "metadata.tenant_key",
                "values" => ["tenant_test"]
              }
            ]} = Jason.decode(match_rules_raw)

    assert [
             %{
               "managed_by" => "setup.gateway.external_org_members",
               "op" => "equals_any",
               "result" => "allow_create_user",
               "source_path" => "metadata.tenant_key",
               "values" => ["tenant_test"]
             }
           ] = AccountsConfig.accounts_authn_match_rules!()
  end

  defp setup_session(conn) do
    Repo.delete_all(ActivationCode)
    {:ok, %{code: plaintext}} = BullXAccounts.create_or_refresh_bootstrap_activation_code()
    {:ok, code_hash} = BullXAccounts.verify_bootstrap_activation_code(plaintext)
    init_test_session(conn, %{bootstrap_activation_code_hash: code_hash})
  end

  defp feishu_entry(attrs \\ %{}) do
    Map.merge(
      %{
        "id" => "feishu:ops-main",
        "adapter" => "feishu",
        "channel_id" => "ops-main",
        "enabled" => true,
        "domain" => "feishu",
        "authn" => %{
          "external_org_members" => %{
            "enabled" => true,
            "tenant_key" => "tenant_test"
          }
        },
        "credentials" => %{
          "app_id" => "cli_test",
          "app_secret" => "secret_test"
        }
      },
      attrs
    )
  end
end
