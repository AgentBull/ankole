defmodule Ankole.Plugins.DingTalkAdapterTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.AppConfig
  alias Ankole.AppConfigure.Cache, as: AppConfigureCache
  alias Ankole.AppConfigure.Crypto, as: AppConfigureCrypto
  alias Ankole.AppConfigure.Registry, as: AppConfigureRegistry
  alias Ankole.AuthZ
  alias Ankole.Plugins.DingTalkAdapter
  alias Ankole.Plugins.DingTalkAdapter.Config
  alias Ankole.Plugins.DingTalkAdapter.IdentityProvider
  alias Ankole.Plugins.DingTalkAdapter.Outbox
  alias Ankole.Principals
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.Binding
  alias Ankole.SignalsGateway.Bindings
  alias Ankole.SignalsGateway.OutboxEntry
  alias DingTalkOpenAPI.Event

  setup do
    previous = Req.default_options()
    on_exit(fn -> Req.default_options(previous) end)
    :ok
  end

  describe "plugin declaration" do
    test "declares the trimmed chat face and the identity face" do
      assert DingTalkAdapter.plugin_id() == "dingtalk-adapter"

      assert [chat, identity] = DingTalkAdapter.adapter_declarations()

      assert chat.contract_id == "signals_gateway.adapter"
      assert chat.id == "dingtalk"
      # DingTalk robots receive only @-mentions and DMs — addressed_only is the
      # sole group message mode this platform can honour.
      assert chat.supported_group_message_modes == ["addressed_only"]
      assert chat.inbound_capabilities == ["entry_receive", "action_event"]
      assert chat.outbound_capabilities == ["post_entry", "delete_entry", "card"]
      assert chat.reply_preview_module == Ankole.Plugins.DingTalkAdapter.AICard

      chat_fields = Map.new(chat.fields, &{&1.path, &1})
      assert chat_fields["clientId"].advanced == false
      assert chat_fields["clientSecret"].advanced == false
      assert chat_fields["robotCode"].advanced == true
      assert chat_fields["cardTemplateId"].advanced == true
      assert chat_fields["platformSubjectNamespace"].advanced == true
      assert chat_fields["userName"].advanced == true

      assert identity.contract_id == "principals.identity_provider"

      assert identity.capabilities == [
               "oidc_authorization",
               "oidc_code_exchange",
               "credential_check",
               "directory_full_sync",
               "directory_realtime_sync"
             ]

      fields = Map.new(identity.fields, &{&1.path, &1})

      assert fields["clientId"].label["zh-Hans-CN"] == "Client ID（原 AppKey）"
      assert fields["clientSecret"].label["zh-Hans-CN"] == "Client Secret（原 AppSecret）"
      assert fields["oidc.scope"].label["zh-Hans-CN"] == "登录权限范围"
      assert fields["sync.contacts"].label["zh-Hans-CN"] == "同步通讯录"
      assert fields["sync.websocket"].label["zh-Hans-CN"] == "实时同步通讯录变更"
      assert fields["sync.pageSize"].label["zh-Hans-CN"] == "每页同步数量"
    end
  end

  test "concurrent DingTalk binding saves validate app ownership from committed database state" do
    setup_dingtalk_config_registry()
    %{principal: first_agent} = agent_fixture()
    %{principal: second_agent} = agent_fixture()
    shared_config = dingtalk_config("ding_concurrent_shared")
    first_config_key = Config.chat_config_key(first_agent.uid)
    cache_pid = Process.whereis(AppConfigureCache)
    parent = self()

    assert {:ok, %{binding: %Binding{}}} =
             Bindings.put_binding(
               first_agent.uid,
               "dingtalk",
               "dingtalk-main",
               dingtalk_binding_attrs(dingtalk_config("ding_concurrent_initial"))
             )

    assert {:ok, %{"clientId" => "ding_concurrent_initial"}} =
             AppConfigure.get_by_key(first_config_key)

    assert {:ok, {:row, _envelope}} = AppConfigureCache.lookup("global", first_config_key)
    :ok = :sys.suspend(cache_pid)

    on_exit(fn ->
      if Process.alive?(cache_pid), do: :sys.resume(cache_pid)
    end)

    first_save =
      Task.async(fn ->
        send(parent, {:ready, self()})
        receive do: (:save -> :ok)

        Bindings.put_binding(
          first_agent.uid,
          "dingtalk",
          "dingtalk-main",
          dingtalk_binding_attrs(shared_config)
        )
      end)

    assert_receive {:ready, first_save_pid}, 1_000
    assert first_save_pid == first_save.pid
    :erlang.trace(first_save.pid, true, [:send])
    send(first_save.pid, :save)

    assert_receive {:trace, ^first_save_pid, :send,
                    {:"$gen_call", _from, {:load, "global", ^first_config_key}}, ^cache_pid},
                   1_000

    second_save =
      Task.async(fn ->
        Bindings.put_binding(
          second_agent.uid,
          "dingtalk",
          "dingtalk-main",
          dingtalk_binding_attrs(shared_config)
        )
      end)

    second_result = Task.yield(second_save, 500)
    :ok = :sys.resume(cache_pid)

    assert {:ok, %{binding: %Binding{agent_uid: first_agent_uid}}} = Task.await(first_save, 1_000)
    assert first_agent_uid == first_agent.uid

    second_result = second_result || {:ok, Task.await(second_save, 1_000)}

    assert {:ok,
            {:error, {:dingtalk_app_already_bound, "ding_concurrent_shared", rejected_owner_uid}}} =
             second_result

    assert rejected_owner_uid == first_agent.uid
    refute Repo.get_by(Binding, agent_uid: second_agent.uid, name: "dingtalk-main")
  end

  test "DingTalk binding ownership fails closed when an enabled owner's config is unavailable" do
    setup_dingtalk_config_registry()
    %{principal: owner} = agent_fixture()
    %{principal: claimant} = agent_fixture()
    owner_config_key = Config.chat_config_key(owner.uid)
    claimed_config = dingtalk_config("ding_claimed_while_owner_unknown")

    assert {:ok, %Binding{}} =
             SignalsGateway.upsert_binding(%{
               agent_uid: owner.uid,
               name: "dingtalk-main",
               adapter: "dingtalk",
               config_ref: "app-config://#{owner_config_key}",
               filters: %{},
               unaddressed_group_message_policy: :ignore,
               enabled: true
             })

    assert {:error, {:dingtalk_binding_config_unavailable, owner_uid, :missing}} =
             Bindings.put_binding(
               claimant.uid,
               "dingtalk",
               "dingtalk-main",
               dingtalk_binding_attrs(claimed_config)
             )

    assert owner_uid == owner.uid

    put_raw_global_config(owner_config_key, %{"type" => "cipher", "value" => "invalid"})

    assert {:error,
            {:dingtalk_binding_config_unavailable, owner_uid,
             {:storage_error, "global", ^owner_config_key, _decrypt_reason}}} =
             Bindings.put_binding(
               claimant.uid,
               "dingtalk",
               "dingtalk-main",
               dingtalk_binding_attrs(claimed_config)
             )

    assert owner_uid == owner.uid

    assert {:ok, invalid_config_ciphertext} =
             AppConfigureCrypto.seal(%{"clientId" => "incomplete"}, "global", owner_config_key)

    put_raw_global_config(owner_config_key, %{
      "type" => "cipher",
      "value" => invalid_config_ciphertext
    })

    assert {:error,
            {:dingtalk_binding_config_unavailable, owner_uid,
             {:storage_error, "global", ^owner_config_key, {:missing, "clientSecret"}}}} =
             Bindings.put_binding(
               claimant.uid,
               "dingtalk",
               "dingtalk-main",
               dingtalk_binding_attrs(claimed_config)
             )

    assert owner_uid == owner.uid
    refute Repo.get_by(Binding, agent_uid: claimant.uid, name: "dingtalk-main")
  end

  # --- outbox ----------------------------------------------------------------

  defp setup_chat_binding(extra_config \\ %{}) do
    setup_dingtalk_config_registry()

    config_id = "dingtalk-outbox-#{System.unique_integer([:positive])}"

    config =
      Map.merge(%{"clientId" => "cli_outbox", "clientSecret" => "secret"}, extra_config)

    {:ok, _config} = AppConfigure.put_global_by_key(Config.chat_config_key(config_id), config)

    %{principal: agent} = agent_fixture()

    {:ok, binding} =
      SignalsGateway.upsert_binding(%{
        agent_uid: agent.uid,
        name: "dingtalk-outbox",
        adapter: "dingtalk",
        config_ref: "app-config://#{Config.chat_config_key(config_id)}",
        filters: %{},
        unaddressed_group_message_policy: :ignore
      })

    binding
  end

  defp setup_dingtalk_config_registry do
    AppConfigureRegistry.clear_for_test()
    AppConfigureCache.clear_for_test()
    :ok = AppConfigure.register_patterns(DingTalkAdapter.app_config_patterns())
  end

  defp dingtalk_binding_attrs(config) do
    %{"config" => config, "group_message_mode" => "addressed_only"}
  end

  defp dingtalk_config(client_id), do: %{"clientId" => client_id, "clientSecret" => "secret"}

  defp put_raw_global_config(key, envelope) do
    AppConfig
    |> where([row], row.scope == "global" and row.key == ^key)
    |> Repo.delete_all()

    %AppConfig{}
    |> AppConfig.changeset(%{scope: "global", key: key, value: envelope})
    |> Repo.insert!()
  end

  defp outbox_entry(binding, attrs) do
    struct!(
      %OutboxEntry{
        agent_uid: binding.agent_uid,
        binding_name: binding.name,
        outbound_key: "test-key-#{System.unique_integer([:positive])}",
        signal_channel_id: "dingtalk:cidG",
        payload: %{},
        fallback_visible_text: "hello"
      },
      attrs
    )
  end

  defp stub_outbox_requests(parent, responder) do
    Req.default_options(
      plug: fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        if conn.request_path == "/v1.0/oauth2/accessToken" do
          Req.Test.json(conn, %{"accessToken" => "app-tok", "expireIn" => 7200})
        else
          send(parent, {:api_call, conn.method, conn.request_path, decode_body(body)})
          responder.(conn)
        end
      end
    )
  end

  defp decode_body(""), do: %{}

  defp decode_body(body) do
    case Torque.decode(body) do
      {:ok, decoded} -> decoded
      _other -> %{"raw" => body}
    end
  end

  defp ok_send_responder(conn) do
    Req.Test.json(conn, %{"processQueryKey" => "pqk-1"})
  end

  # App tokens are cached per credential set, so a check test needs its own id.
  defp unique_suffix, do: System.unique_integer([:positive])

  test "post maps markdown to sampleMarkdown chunks and records the processQueryKey" do
    binding = setup_chat_binding()

    entry =
      outbox_entry(binding, %{
        operation: :post,
        fallback_visible_text: "# Title\n\nsome **markdown** body"
      })

    stub_outbox_requests(self(), &ok_send_responder/1)
    assert {:ok, result} = Outbox.send(entry)

    assert_receive {:api_call, "POST", "/v1.0/robot/groupMessages/send", body}
    assert body["msgKey"] == "sampleMarkdown"
    assert body["openConversationId"] == "cidG"
    assert body["robotCode"] == "cli_outbox"
    assert body["msgParam"] =~ "markdown"
    assert result.created_source_entry_id == "pqk-1"
  end

  test "per-user flow control surfaces as a retryable rate limit" do
    binding = setup_chat_binding()
    entry = outbox_entry(binding, %{operation: :post, fallback_visible_text: "plain"})

    responder = fn conn ->
      Req.Test.json(conn, %{"processQueryKey" => "pqk", "flowControlledStaffIdList" => ["u1"]})
    end

    stub_outbox_requests(self(), responder)

    assert {:error, {:provider_error, %{reason: :rate_limited}}} = Outbox.send(entry)
  end

  test "a disbanded group classifies as target_gone" do
    binding = setup_chat_binding()
    entry = outbox_entry(binding, %{operation: :post, fallback_visible_text: "plain"})

    responder = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        400,
        Torque.encode!(%{"code" => "group.disbanded", "message" => "gone"})
      )
    end

    stub_outbox_requests(self(), responder)

    assert {:error, {:provider_error, %{reason: :target_gone, code: "group.disbanded"}}} =
             Outbox.send(entry)
  end

  test "delete recalls by processQueryKey and rejects entries this adapter never sent" do
    binding = setup_chat_binding()

    entry =
      outbox_entry(binding, %{operation: :delete, target_source_entry_id: "pqk-recall"})

    stub_outbox_requests(self(), &ok_send_responder/1)
    assert {:ok, _result} = Outbox.send(entry)

    assert_receive {:api_call, "POST", "/v1.0/robot/groupMessages/recall", body}
    assert body["processQueryKeys"] == ["pqk-recall"]

    assert {:error, :unsupported_target} =
             Outbox.send(outbox_entry(binding, %{operation: :delete}))
  end

  test "an unlisted attachment extension fails explicitly before touching the worker" do
    binding = setup_chat_binding()

    unsupported_entry =
      outbox_entry(binding, %{
        operation: :post,
        payload: %{
          "attachments" => [
            %{"user_files_relative_path" => "outbox-test/program.exe", "name" => "program.exe"}
          ]
        }
      })

    # The sampleFile type list is a strict whitelist: unlisted extensions fail
    # before any worker file read.
    stub_outbox_requests(self(), &ok_send_responder/1)
    assert {:error, :unsupported_file_type} = Outbox.send(unsupported_entry)

    refute_received {:api_call, _method, _path, _body}
  end

  test "a card operation delivers a template instance keyed by the idempotency key" do
    binding = setup_chat_binding(%{"cardTemplateId" => "tpl-1"})

    entry =
      outbox_entry(binding, %{
        operation: :card,
        idempotency_key: "card-idem-1",
        fallback_visible_text: "Pick one",
        payload: %{
          "interactive_output" => %{
            "body" => "Pick one",
            "interaction_id" => "int-9",
            "control_id" => "choice",
            "source_actor_event_id" => "evt-9",
            "version" => 3,
            "choices" => [%{"id" => "a", "label" => "A", "value" => "va"}]
          }
        }
      })

    stub_outbox_requests(self(), &ok_send_responder/1)
    assert {:ok, result} = Outbox.send(entry)
    assert result.created_source_entry_id == "ankole:outbox:card-idem-1"

    assert_receive {:api_call, "POST", "/v1.0/card/instances/createAndDeliver", body}
    assert body["outTrackId"] == "ankole:outbox:card-idem-1"
    assert body["cardTemplateId"] == "tpl-1"

    actions = body |> get_in(["cardData", "cardParamMap", "actions"]) |> Torque.decode!()

    assert [%{"value" => %{"interactionId" => "int-9", "sourceActorEventId" => "evt-9"}}] =
             actions
  end

  test "a card operation without a template posts the fallback text instead" do
    binding = setup_chat_binding()

    entry =
      outbox_entry(binding, %{
        operation: :card,
        fallback_visible_text: "Pick one",
        payload: %{"interactive_output" => %{"body" => "Pick one"}}
      })

    stub_outbox_requests(self(), &ok_send_responder/1)
    assert {:ok, _result} = Outbox.send(entry)

    assert_receive {:api_call, "POST", "/v1.0/robot/groupMessages/send", body}
    assert body["msgParam"] =~ "Pick one"
    refute_received {:api_call, _method, "/v1.0/card/instances/createAndDeliver", _body}
  end

  # --- identity provider -------------------------------------------------------

  defp stub_identity_requests(parent, users) do
    Req.default_options(
      plug: fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request_body = decode_body(body)
        send(parent, {:idp_call, conn.request_path, request_body})

        cond do
          conn.request_path == "/v1.0/oauth2/accessToken" ->
            Req.Test.json(conn, %{"accessToken" => "app-tok", "expireIn" => 7200})

          conn.request_path == "/v1.0/oauth2/userAccessToken" ->
            Req.Test.json(conn, %{
              "accessToken" => "user-tok",
              "refreshToken" => "refresh",
              "expireIn" => 7200,
              "corpId" => "corp-1"
            })

          conn.request_path == "/v1.0/contact/users/me" ->
            Req.Test.json(conn, %{"nick" => "Ada", "unionId" => "union-1"})

          conn.request_path == "/topapi/user/getbyunionid" ->
            Req.Test.json(conn, %{"errcode" => 0, "result" => %{"userid" => "staff-1"}})

          conn.request_path == "/topapi/v2/department/listsub" ->
            case request_body["dept_id"] do
              1 ->
                Req.Test.json(conn, %{
                  "errcode" => 0,
                  "result" => [%{"dept_id" => 20, "name" => "研发部", "parent_id" => 1}]
                })

              _sub ->
                Req.Test.json(conn, %{"errcode" => 0, "result" => []})
            end

          conn.request_path == "/topapi/v2/user/list" ->
            Req.Test.json(conn, %{
              "errcode" => 0,
              "result" => %{
                "has_more" => false,
                "list" => if(request_body["dept_id"] == 20, do: users, else: [])
              }
            })

          conn.request_path == "/topapi/v2/user/get" ->
            userid = request_body["userid"]

            case Enum.find(users, &(&1["userid"] == userid)) do
              nil -> Req.Test.json(conn, %{"errcode" => 60_121, "errmsg" => "user not found"})
              user -> Req.Test.json(conn, %{"errcode" => 0, "result" => user})
            end

          true ->
            Req.Test.json(conn, %{"errcode" => 0, "result" => %{}})
        end
      end
    )
  end

  @identity_config %{
    "clientId" => "cli_idp",
    "clientSecret" => "secret",
    "oidc" => %{"enabled" => true, "scope" => "openid corpid"},
    "sync" => %{"contacts" => true, "websocket" => true, "pageSize" => 50}
  }

  test "the login chain resolves authCode to a hydrated enterprise userid" do
    users = [
      %{
        "userid" => "staff-1",
        "name" => "Ada Ling",
        "unionid" => "union-1",
        "org_email" => "ada@corp.example",
        "email" => "ada@personal.example",
        "dept_id_list" => [20]
      }
    ]

    stub_identity_requests(self(), users)

    assert {:ok, %{token: token, user: user}} =
             IdentityProvider.exchange_code(@identity_config, "auth-code-1")

    assert token.corp_id == "corp-1"
    assert user["userid"] == "staff-1"
    assert user["name"] == "Ada Ling"
    assert user["corp_id"] == "corp-1"

    assert_receive {:idp_call, "/v1.0/oauth2/userAccessToken", %{"code" => "auth-code-1"}}
    assert_receive {:idp_call, "/v1.0/contact/users/me", _body}
    assert_receive {:idp_call, "/topapi/user/getbyunionid", %{"unionid" => "union-1"}}
    assert_receive {:idp_call, "/topapi/v2/user/get", %{"userid" => "staff-1"}}
  end

  test "a unionid with no employee fails the login closed" do
    Req.default_options(
      plug: fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn)

        case conn.request_path do
          "/v1.0/oauth2/userAccessToken" ->
            Req.Test.json(conn, %{"accessToken" => "user-tok", "expireIn" => 7200})

          "/v1.0/contact/users/me" ->
            Req.Test.json(conn, %{"unionId" => "outsider"})

          "/v1.0/oauth2/accessToken" ->
            Req.Test.json(conn, %{"accessToken" => "app-tok", "expireIn" => 7200})

          "/topapi/user/getbyunionid" ->
            Req.Test.json(conn, %{"errcode" => 60_121, "errmsg" => "no employee"})
        end
      end
    )

    assert {:error, %DingTalkOpenAPI.Error{reason: :not_found}} =
             IdentityProvider.exchange_code(@identity_config, "outsider-code")
  end

  test "authorization_url carries the configured scope and fails closed when disabled" do
    assert {:ok, url} =
             IdentityProvider.authorization_url(@identity_config,
               redirect_uri: "https://ankole.example/auth/callback",
               state: "state-1"
             )

    assert url =~ "https://login.dingtalk.com/oauth2/auth?"
    assert url =~ "scope=openid+corpid"
    assert url =~ "state=state-1"

    disabled = put_in(@identity_config, ["oidc", "enabled"], false)

    assert {:error, :oidc_disabled} =
             IdentityProvider.authorization_url(disabled,
               redirect_uri: "https://ankole.example/auth/callback",
               state: "state-1"
             )
  end

  test "credential check separates a rejected Client ID from an accepted one" do
    accepted = %{@identity_config | "clientId" => "cli_idp_accepted_#{unique_suffix()}"}
    rejected = %{@identity_config | "clientId" => "cli_idp_rejected_#{unique_suffix()}"}
    accepted_client_id = accepted["clientId"]

    Req.default_options(
      plug: fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        case decode_body(body)["appKey"] == accepted_client_id do
          true ->
            Req.Test.json(conn, %{"accessToken" => "app-tok", "expireIn" => 7200})

          false ->
            conn
            |> Plug.Conn.put_status(400)
            |> Req.Test.json(%{
              "code" => "invalidClientIdOrSecret",
              "message" => "无效的clientId或者clientSecret"
            })
        end
      end
    )

    assert :ok = IdentityProvider.check_credentials(accepted)

    assert {:error, %DingTalkOpenAPI.Error{code: "invalidClientIdOrSecret"}} =
             IdentityProvider.check_credentials(rejected)
  end

  test "full directory sync builds the department tree and upserts users preferring org_email" do
    provider_id = "dingtalk-idp-#{System.unique_integer([:positive])}"

    users = [
      %{
        "userid" => "staff-1",
        "name" => "Ada Ling",
        "unionid" => "union-1",
        "org_email" => "ada@corp.example",
        "email" => "ada@personal.example",
        "title" => "Engineer",
        "dept_id_list" => [20]
      }
    ]

    stub_identity_requests(self(), users)

    assert {:ok, %{users: 1, departments: 1}} =
             IdentityProvider.sync_directory(provider_id, @identity_config)

    assert [_group_id] = AuthZ.external_group_ids(provider_id, :directory_department, "20")

    assert {:ok, principal} = Principals.resolve_platform_subject(provider_id, "staff-1")
    assert principal.display_name == "Ada Ling"

    human_user = Repo.get!(Ankole.Principals.HumanUser, principal.uid)
    assert human_user.email == "ada@corp.example"
  end

  test "contact events requery per id, ignore admin churn, and disable departed users" do
    provider_id = "dingtalk-idp-#{System.unique_integer([:positive])}"

    users = [
      %{"userid" => "staff-2", "name" => "Bo", "unionid" => "union-2", "dept_id_list" => [20]}
    ]

    stub_identity_requests(self(), users)
    consumer = IdentityProvider.identity_consumer(provider_id, @identity_config)

    add_event = %Event{
      type: "EVENT",
      event_type: "user_add_org",
      data: %{"userId" => ["staff-2"]}
    }

    assert {:ok, [%{status: :upserted, count: 1}]} =
             IdentityProvider.handle_contact_event("user_add_org", add_event, [consumer])

    assert {:ok, principal} = Principals.resolve_platform_subject(provider_id, "staff-2")

    admin_event = %Event{type: "EVENT", event_type: "org_admin_add", data: %{}}

    assert {:ok, [%{status: :ignored_admin_change}]} =
             IdentityProvider.handle_contact_event("org_admin_add", admin_event, [consumer])

    leave_event = %Event{
      type: "EVENT",
      event_type: "user_leave_org",
      data: %{"userId" => ["staff-2"]}
    }

    assert {:ok, [%{status: :users_disabled, count: 1}]} =
             IdentityProvider.handle_contact_event("user_leave_org", leave_event, [consumer])

    # The departed subject is disabled directly — a full sync only upserts and
    # would have left the Principal active forever.
    assert {:error, _disabled} = Principals.resolve_platform_subject(provider_id, "staff-2")
    assert Repo.get!(Ankole.Principals.Principal, principal.uid).status == :disabled
  end
end
