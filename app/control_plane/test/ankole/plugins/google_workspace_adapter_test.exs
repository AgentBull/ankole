defmodule Ankole.Plugins.GoogleWorkspaceAdapterTest do
  use Ankole.DataCase, async: false

  alias Ankole.AppConfigure
  alias Ankole.AuthZ
  alias Ankole.AuthZ.Membership
  alias Ankole.Plugins.GoogleWorkspaceAdapter
  alias Ankole.Plugins.GoogleWorkspaceAdapter.{Config, IdentityProvider}
  alias Ankole.Plugins.Registry
  alias Ankole.Principals

  alias Ankole.AppConfigure.Cache, as: AppConfigureCache
  alias Ankole.AppConfigure.Registry, as: AppConfigureRegistry

  # Throwaway RSA pair shared with the kernel test fixtures; it protects nothing.
  @rsa_private_key_pem """
  -----BEGIN PRIVATE KEY-----
  MIIEvAIBADANBgkqhkiG9w0BAQEFAASCBKYwggSiAgEAAoIBAQC+gCGds9mjKTXp
  QnkwFc1fTxxdhHe7YBBUJf+vLMMS0pTL49TOTb0xJ/fZ/QB1iN0KppO9rxdzxWDv
  sN4HM1UaIPEpmBjY+nevh7Ta9kdKQgXlpZd87Otz5kewmqE6Z/WFET0uMCjpnB7j
  xnJ4f0xooXQFtXnJTxZbd53Q6CUKBFPE7WiKAh5HCteuJnQgOcEdqRjRelcBxEIE
  d8KoDshIsSzyoD68AGGVBnQbaRqoYnyHULjGgHapqyIqoa7zPv/dHIfYzXhRRJcb
  +klyqde7hfNAtbmJxaxpOAwdB7uSL+7YV9V1Aqx0NtgGkefSmT+vWtoWYSzeYMBP
  jEC9FlOFAgMBAAECggEAVRS47swiiaKgN1u+8GDsZoLYslO1ffQ7lrmZ5kzhmwh9
  +En7A2Do/IlTQwKiL9w+jME0/uSyXrxqvOKLZz/f5FmOG/uYLWBAEB9WAO05jcrL
  A3PfoqXVyt+waQnGtGU13IaEgppzy1I04ZoCChsgryJcxSf2CpjN7XARBfqIgF4D
  YncHS9JkTgtiC8ojHgmf302uWtbdofNjqbjG/VoP+KzJu9OsTtbn/p7ktmgWhviO
  Jqmqs5b/LQq3laHrYFB7fViurG3XHozRL8aQ4R7MnlaclwB5th1SQcBV5q++7t87
  5qyy/uld/iFPZmC3TfIO/DM3Jg+e7xEyBuM4bFgRyQKBgQD8OOkNSwvjVfW/80IV
  DPxixFxj2z1lunbzY5YxOn/yqXmvMpfCNl2qc8o1TfUBrjVOe/N/HL0HtPEwXbS2
  T0QzRUPccpi29HELQR67yP0r+z6u8Rbq/v7W4B7Wjd99yfTE+jw2q77rPevUW53p
  nYkKDDqV1xIC2iXA9DwpzdRjFwKBgQDBWpAI3gEyYlkMrqDcUY7vnUdW+Js40KAM
  ldJ3SxbBcmUSljtRYakpp/iJ1UzxDO+vP9w1HyO0VIPjR2BOhpgFlaiHz2Z9a0aL
  BxAYNGQvXuxDgn8EXFxNfQqEylqxR0s2+FvNbJHZmcufNlA3Gp7Z578jMXLW+Xi3
  4eNGo9OPwwKBgA4d0U1hKeUrZnm7z7MF6wpMGy+rkaAj84xjwoA22fpm6dyYZE4G
  ZO+pU2PwXQofCfS+kz5GCX5o7iba18ZsYVDNS6MG9u0meT08A9BWy3Suty9rZvD4
  HKNCH/e6MQwFRaHQr5YPvrvD13MnPYtZudXKIW1JgESQmRRXlxZv4rc5AoGAblvg
  Zg9Ao59asFBj5Bxw9vbQJyXSgsUg9M32yLwFCvjeE5PH25VgVjRXOWSTe+okS+Sp
  LXDOkjjC5lBw+aD82AMppAqOtvsp0mR/nTEaFaeaNpYfJUAKNvgtrslIpnLIzWFI
  FKHpRUfw3rjDZBA/pqQNhmrM30KY0muNq14KfL0CgYAh2PBtHyY09Or7uLkPr8kG
  zsgVAle6vjE4r3s5cNO5hkqQs2kkfCklHZWFbDZ26r5hwmFHlbgF9X/K+JTPrZVh
  9f2PcI2LK9M1y/YkgTx+qSc0ROLtMrfKz6XOX6WSBwl2CY2XYJh6gRwvWG88mjJ+
  WcIZW/EN2+olnpMjA71EXA==
  -----END PRIVATE KEY-----
  """

  setup do
    # Earlier suites in the same run may clear the global AppConfigure
    # registries, so config-key writes re-register this plugin's patterns.
    AppConfigureRegistry.clear_for_test()
    AppConfigureCache.clear_for_test()
    :ok = AppConfigure.register_patterns(GoogleWorkspaceAdapter.app_config_patterns())
    previous = Req.default_options()
    on_exit(fn -> Req.default_options(previous) end)
  end

  describe "plugin and config contracts" do
    test "declares one identity contract without realtime sync" do
      assert GoogleWorkspaceAdapter.plugin_id() == "google-workspace-adapter"

      assert [
               %{
                 contract_id: "principals.identity_provider",
                 id: "google-workspace",
                 module: IdentityProvider,
                 capabilities: capabilities
               }
             ] = GoogleWorkspaceAdapter.adapter_declarations()

      assert capabilities == ["oidc_authorization", "oidc_code_exchange", "directory_full_sync"]
      refute "directory_realtime_sync" in capabilities
      assert Enum.all?(GoogleWorkspaceAdapter.app_config_patterns(), & &1.encrypted)

      [identity] = GoogleWorkspaceAdapter.adapter_declarations()
      fields = Map.new(identity.fields, &{&1.path, &1})

      assert fields["clientID"].requiredWhen == [%{path: "oidc.enabled", value: true}]
      assert fields["clientSecret"].requiredWhen == [%{path: "oidc.enabled", value: true}]
      assert fields["oidc.allowedDomains"].requiredWhen == [%{path: "oidc.enabled", value: true}]
      assert fields["serviceAccountKey"].requiredWhen == [%{path: "sync.contacts", value: true}]
      assert fields["adminEmail"].requiredWhen == [%{path: "sync.contacts", value: true}]
      assert fields["clientID"].label["zh-Hans-CN"] == "OAuth 客户端 ID"
      assert fields["clientSecret"].label["zh-Hans-CN"] == "OAuth 客户端密钥"
      assert fields["oidc.scopes"].label["zh-Hans-CN"] == "登录权限范围"
      assert fields["serviceAccountKey"].label["zh-Hans-CN"] == "服务账号 JSON 密钥"
      assert fields["adminEmail"].label["zh-Hans-CN"] == "委派管理员邮箱"
      assert fields["sync.contacts"].label["zh-Hans-CN"] == "同步通讯录"
      assert fields["sync.pageSize"].label["zh-Hans-CN"] == "每页同步数量"

      assert fields["oidc.allowedDomains"].validation.pattern ==
               "^[A-Za-z0-9][A-Za-z0-9.-]*\\.[A-Za-z]{2,}$"

      assert fields["serviceAccountKey"].validation == %{
               kind: "json_object",
               requiredStringProperties: ["client_email", "private_key"],
               stringPrefixes: %{"private_key" => "-----BEGIN"},
               message: %{
                 "default" =>
                   "Paste a service account JSON key that contains client_email and private_key.",
                 "zh-Hans-CN" => "请粘贴包含 client_email 和 private_key 的服务账号 JSON 密钥。"
               }
             }

      assert fields["adminEmail"].validation.pattern == "^[^\\s@]+@[^\\s@]+$"
    end

    test "the booted registry discovered and validated the plugin" do
      assert {:ok, plugin} = Registry.get("google-workspace-adapter")
      assert plugin.id == "google-workspace-adapter"

      adapter =
        Enum.find(
          Ankole.IdentityProviders.list_adapters(),
          &(&1.adapter_id == "google-workspace")
        )

      assert adapter.plugin_id == "google-workspace-adapter"
      assert adapter.default_provider_id == "google-workspace-main"
      assert adapter.connection_reconciler == nil
    end

    test "identity validation requires allowed domains for login" do
      assert {:error, {:missing, "oidc.allowedDomains"}} =
               Config.validate_identity_config(%{
                 "clientID" => "client-1",
                 "clientSecret" => "secret-1",
                 "serviceAccountKey" => service_account_key_json(),
                 "adminEmail" => "admin@example.com"
               })

      assert {:error, {:invalid_domain, "oidc.allowedDomains"}} =
               Config.validate_identity_config(
                 identity_config(%{"oidc" => %{"allowedDomains" => ["not a domain"]}})
               )

      assert {:ok, config} = Config.validate_identity_config(identity_config())
      assert config["oidc"]["allowedDomains"] == ["example.com"]
      assert config["oidc"]["scopes"] == ["openid", "email", "profile"]
      assert config["sync"]["pageSize"] == 500
    end

    test "identity validation scopes credentials to the enabled halves" do
      # Directory-only: no OAuth client needed.
      assert {:ok, sync_only} =
               Config.validate_identity_config(%{
                 "oidc" => %{"enabled" => false},
                 "serviceAccountKey" => service_account_key_json(),
                 "adminEmail" => "Admin@Example.com"
               })

      assert sync_only["clientID"] == nil
      assert sync_only["adminEmail"] == "admin@example.com"

      # Login-only: no service account needed.
      assert {:ok, login_only} =
               Config.validate_identity_config(%{
                 "clientID" => "client-1",
                 "clientSecret" => "secret-1",
                 "oidc" => %{"allowedDomains" => ["Example.COM"]},
                 "sync" => %{"contacts" => false}
               })

      assert login_only["serviceAccountKey"] == nil
      assert login_only["oidc"]["allowedDomains"] == ["example.com"]

      assert {:error, {:missing, "clientID"}} =
               Config.validate_identity_config(%{
                 "oidc" => %{"allowedDomains" => ["example.com"]},
                 "sync" => %{"contacts" => false}
               })

      assert {:error, {:missing, "adminEmail"}} =
               Config.validate_identity_config(identity_config(%{"adminEmail" => nil}))
    end

    test "service account keys must parse with usable key material" do
      assert {:error, :invalid_service_account_key} =
               Config.validate_identity_config(
                 identity_config(%{"serviceAccountKey" => "not json"})
               )

      assert {:error, :invalid_service_account_key} =
               Config.validate_identity_config(
                 identity_config(%{
                   "serviceAccountKey" => Torque.encode!(%{"client_email" => "sa@proj.iam.test"})
                 })
               )

      {:ok, config} = Config.validate_identity_config(identity_config())
      assert {:ok, account} = Config.service_account(config)
      assert account.email == "sa@proj.iam.gserviceaccount.com"
      assert account.key_id == "sa-key-1"
      assert String.starts_with?(account.private_key, "-----BEGIN")
    end
  end

  describe "OIDC login" do
    test "authorization_url hints a single domain" do
      {:ok, config} = Config.validate_identity_config(identity_config())

      assert {:ok, url} =
               IdentityProvider.authorization_url(config,
                 redirect_uri: "https://ankole.example.com/cb",
                 state: "state-1"
               )

      query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
      assert query["hd"] == "example.com"
      assert query["client_id"] == "client-1"
    end

    test "verify_login_claims fails closed on every gate" do
      {:ok, config} = Config.validate_identity_config(identity_config())

      valid = %{
        "sub" => "103200300400500600700",
        "email" => "Ada@Example.com",
        "email_verified" => true,
        "hd" => "example.com"
      }

      assert :ok = IdentityProvider.verify_login_claims(valid, config)

      assert {:error, :email_unverified} =
               IdentityProvider.verify_login_claims(
                 Map.put(valid, "email_verified", false),
                 config
               )

      assert {:error, :not_workspace_account} =
               IdentityProvider.verify_login_claims(Map.delete(valid, "hd"), config)

      assert {:error, :login_domain_not_allowed} =
               IdentityProvider.verify_login_claims(
                 Map.put(valid, "hd", "attacker.example.net"),
                 config
               )

      assert {:error, :login_domain_not_allowed} =
               IdentityProvider.verify_login_claims(
                 Map.put(valid, "email", "ada@attacker.example.net"),
                 config
               )
    end

    test "exchange_code trades the code, reads userinfo, and enforces the domain" do
      {:ok, config} = Config.validate_identity_config(identity_config())

      Req.Test.stub(__MODULE__, fn conn ->
        case conn.request_path do
          "/token" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            form = URI.decode_query(body)
            assert form["grant_type"] == "authorization_code"
            assert form["code"] == "code-1"
            Req.Test.json(conn, %{"access_token" => "at-1", "expires_in" => 3599})

          "/v1/userinfo" ->
            assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer at-1"]

            Req.Test.json(conn, %{
              "sub" => "103200300400500600700",
              "email" => "Ada@Example.com",
              "email_verified" => true,
              "hd" => "example.com",
              "name" => "Ada Lovelace"
            })
        end
      end)

      use_req_test!()

      assert {:ok, %{user: user}} =
               IdentityProvider.exchange_code(config, "code-1",
                 redirect_uri: "https://ankole.example.com/cb"
               )

      assert user["id"] == "103200300400500600700"
      assert user["primaryEmail"] == "ada@example.com"
      assert user["name"] == "Ada Lovelace"
    end

    test "exchange_code rejects accounts outside the allowed domains" do
      {:ok, config} = Config.validate_identity_config(identity_config())

      Req.Test.stub(__MODULE__, fn conn ->
        case conn.request_path do
          "/token" ->
            Req.Test.json(conn, %{"access_token" => "at-1", "expires_in" => 3599})

          "/v1/userinfo" ->
            Req.Test.json(conn, %{
              "sub" => "42",
              "email" => "mallory@gmail.com",
              "email_verified" => true
            })
        end
      end)

      use_req_test!()

      assert {:error, :not_workspace_account} =
               IdentityProvider.exchange_code(config, "code-1",
                 redirect_uri: "https://ankole.example.com/cb"
               )
    end
  end

  describe "directory sync" do
    test "full sync signs the grant, projects groups then users, and filters suspended" do
      {:ok, config} = Config.validate_identity_config(identity_config())
      parent = self()

      Req.Test.stub(__MODULE__, fn conn ->
        case conn.request_path do
          "/token" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            form = URI.decode_query(body)
            assert form["grant_type"] == "urn:ietf:params:oauth:grant-type:jwt-bearer"
            send(parent, {:assertion, form["assertion"]})
            Req.Test.json(conn, %{"access_token" => "sa-token", "expires_in" => 3600})

          "/admin/directory/v1/groups" ->
            assert URI.decode_query(conn.query_string)["customer"] == "my_customer"

            Req.Test.json(conn, %{
              "groups" => [
                %{"id" => "g-eng", "name" => "Engineering", "email" => "eng@example.com"}
              ]
            })

          "/admin/directory/v1/groups/g-eng/members" ->
            Req.Test.json(conn, %{
              "members" => [
                %{"id" => "103200300400500600700", "type" => "USER", "status" => "ACTIVE"},
                %{"id" => "g-nested", "type" => "GROUP"}
              ]
            })

          "/admin/directory/v1/users" ->
            Req.Test.json(conn, %{
              "users" => [
                %{
                  "id" => "103200300400500600700",
                  "primaryEmail" => "ada@example.com",
                  "name" => %{"fullName" => "Ada Lovelace"},
                  "orgUnitPath" => "/Engineering",
                  "organizations" => [%{"title" => "Engineer"}],
                  "phones" => [%{"type" => "mobile", "value" => "+14155552671"}]
                },
                %{
                  "id" => "200000000000000000002",
                  "primaryEmail" => "gone@example.com",
                  "suspended" => true
                }
              ]
            })
        end
      end)

      use_req_test!()

      assert {:ok, %{users: 1, groups: 1}} =
               IdentityProvider.sync_directory("google-workspace-main", config)

      # The grant assertion is a kernel-signed RS256 JWT carrying the
      # delegated admin subject.
      assert_received {:assertion, assertion}
      [_header, payload, _signature] = String.split(assertion, ".")
      {:ok, claims_json} = Base.url_decode64(payload, padding: false)
      {:ok, claims} = Torque.decode(claims_json)
      assert claims["iss"] == "sa@proj.iam.gserviceaccount.com"
      assert claims["sub"] == "admin@example.com"

      assert {:ok, uid} =
               Principals.resolve_platform_subject_uid(
                 "google-workspace-main",
                 "103200300400500600700"
               )

      assert {:ok, principal} = Principals.get_principal(uid)
      assert principal.display_name == "Ada Lovelace"

      [group_id] =
        AuthZ.external_group_ids("google-workspace-main", :directory_department, "g-eng")

      assert Repo.get_by(Membership, principal_uid: uid, group_id: group_id)

      assert {:error, :not_found} =
               Principals.resolve_platform_subject_uid(
                 "google-workspace-main",
                 "200000000000000000002"
               )
    end

    test "directory upsert joins the existing Slack principal by email" do
      assert {:ok, slack} =
               Principals.upsert_platform_subject_human(%{
                 provider: "slack-main",
                 external_id: "U7000",
                 uid: "U7000",
                 display_name: "Ada",
                 email: "ada.join@example.com"
               })

      assert {:ok, observed} =
               IdentityProvider.upsert_user("google-workspace-main", %{
                 "id" => "103999999999999999999",
                 "primaryEmail" => "Ada.Join@Example.com",
                 "name" => %{"fullName" => "Ada Lovelace"}
               })

      assert observed.principal.uid == slack.principal.uid
      assert observed.identity.provider == "google-workspace-main"

      assert {:ok, resolved} =
               Principals.resolve_platform_subject_uid("slack-main", "U7000")

      assert resolved == observed.principal.uid
    end
  end

  defp identity_config(overrides \\ %{}) do
    Map.merge(
      %{
        "clientID" => "client-1",
        "clientSecret" => "secret-1",
        "oidc" => %{"allowedDomains" => ["example.com"]},
        "serviceAccountKey" => service_account_key_json(),
        "adminEmail" => "admin@example.com"
      },
      overrides
    )
  end

  defp service_account_key_json do
    Torque.encode!(%{
      "type" => "service_account",
      "client_email" => "sa@proj.iam.gserviceaccount.com",
      "private_key" => @rsa_private_key_pem,
      "private_key_id" => "sa-key-1"
    })
  end

  defp use_req_test!, do: Req.default_options(plug: {Req.Test, __MODULE__})
end
