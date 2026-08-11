defmodule Ankole.Plugins.WeComAdapterTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Cache, as: AppConfigureCache
  alias Ankole.AppConfigure.Registry, as: AppConfigureRegistry
  alias Ankole.Plugins.WeComAdapter
  alias Ankole.Plugins.WeComAdapter.Config
  alias Ankole.Plugins.WeComAdapter.ConnectionOwner
  alias Ankole.Plugins.WeComAdapter.IdentityProvider
  alias Ankole.Plugins.WeComAdapter.Outbox
  alias Ankole.Plugins.WeComAdapter.TemplateCard
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.Adapters
  alias Ankole.SignalsGateway.Channel
  alias Ankole.SignalsGateway.OutboxEntry

  setup do
    previous = Req.default_options()
    on_exit(fn -> Req.default_options(previous) end)
    :ok
  end

  describe "plugin declaration" do
    test "declares the trimmed chat face and the identity face" do
      assert WeComAdapter.plugin_id() == "wecom-adapter"

      assert [chat, identity] = WeComAdapter.adapter_declarations()

      assert chat.contract_id == "signals_gateway.adapter"
      assert chat.id == "wecom"
      # WeCom AI bots receive only @-mentions and DMs — addressed_only is the
      # sole group message mode this platform can honour.
      assert chat.supported_group_message_modes == ["addressed_only"]
      assert chat.inbound_capabilities == ["entry_receive", "action_event"]
      # No recall API on the bot surface — delete_entry is deliberately absent.
      assert chat.outbound_capabilities == ["post_entry", "card"]
      assert chat.reply_preview_module == Ankole.Plugins.WeComAdapter.AIStream
      assert :ok = Adapters.validate_declaration(chat)

      chat_fields = Map.new(chat.fields, &{&1.path, &1})
      assert chat_fields["botId"].advanced == false
      assert chat_fields["secret"].advanced == false
      assert chat_fields["platformSubjectNamespace"].advanced == true
      assert chat_fields["userName"].advanced == true

      assert identity.contract_id == "principals.identity_provider"

      # No directory_realtime_sync: contact-change events need a public XML
      # callback URL; changes converge through periodic full sync.
      assert identity.capabilities == [
               "oidc_authorization",
               "oidc_code_exchange",
               "credential_check",
               "directory_full_sync"
             ]
    end
  end

  describe "config validation" do
    test "chat config requires botId and secret" do
      assert {:ok, config} =
               Config.validate_chat_config(%{"botId" => "bot-1", "secret" => "s"})

      assert config["platformSubjectNamespace"] == "wecom-main"
      assert config["group_message_mode"] == "addressed_only"

      assert {:error, {:missing, "secret"}} = Config.validate_chat_config(%{"botId" => "b"})
    end

    test "identity config refuses directory sync without the contacts-sync secret" do
      base = %{"corpId" => "ww1", "agentId" => "1000002", "appSecret" => "as"}

      assert {:error, :contacts_secret_required} = Config.validate_identity_config(base)

      assert {:ok, disabled} =
               Config.validate_identity_config(Map.put(base, "sync", %{"contacts" => false}))

      assert disabled["sync"]["contacts"] == false

      assert {:ok, full} =
               Config.validate_identity_config(Map.put(base, "contactsSecret", "cs"))

      assert full["sync"]["contacts"] == true
      assert full["contactsSecret"] == "cs"
    end
  end

  # --- delivery resolution ---------------------------------------------------

  defp seed_channel(id, attrs) do
    %Channel{}
    |> Channel.changeset(
      Map.merge(
        %{
          id: id,
          kind: :im_dm,
          reply_mode: :channel,
          metadata: %{},
          first_seen_at: DateTime.utc_now(),
          last_seen_at: DateTime.utc_now()
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  describe "resolve_delivery" do
    test "DM channels resolve the counterpart userid and a fresh respond anchor" do
      seed_channel("wecom:alice", %{
        kind: :im_dm,
        metadata: %{
          "dm_user_id" => "alice",
          "last_req_id" => "req-9",
          "last_req_at" => DateTime.to_iso8601(DateTime.utc_now())
        }
      })

      assert {:ok, %{chat_target: "alice", chat_type: 1, respond_req_id: "req-9"}} =
               Outbox.resolve_delivery("wecom:alice")
    end

    test "an anchor beyond the 24-hour reply window falls back to proactive send" do
      stale = DateTime.utc_now() |> DateTime.add(-25 * 60 * 60) |> DateTime.to_iso8601()

      seed_channel("wecom:bob", %{
        kind: :im_dm,
        metadata: %{"dm_user_id" => "bob", "last_req_id" => "req-old", "last_req_at" => stale}
      })

      assert {:ok, %{chat_target: "bob", chat_type: 1, respond_req_id: nil}} =
               Outbox.resolve_delivery("wecom:bob")
    end

    test "group channels decode the chatid; unknown channels stay group-shaped" do
      seed_channel("wecom:wr-g1", %{kind: :im_group, metadata: %{"last_req_id" => "req-g"}})

      # A group anchor without a timestamp does not count as fresh.
      assert {:ok, %{chat_target: "wr-g1", chat_type: 2, respond_req_id: nil}} =
               Outbox.resolve_delivery("wecom:wr-g1")

      assert {:ok, %{chat_target: "wr-x", chat_type: 2, respond_req_id: nil}} =
               Outbox.resolve_delivery("wecom:wr-x")
    end

    test "a DM channel without a recorded counterpart fails closed" do
      seed_channel("wecom:mystery", %{kind: :im_dm, metadata: %{}})
      assert {:error, :dm_recipient_unknown} = Outbox.resolve_delivery("wecom:mystery")
    end
  end

  # --- outbox through a fake bot connection ----------------------------------

  defmodule FakeBotClient do
    use GenServer

    def start_link(key, parent, script \\ %{}) do
      GenServer.start_link(__MODULE__, {parent, script}, name: ConnectionOwner.client_name(key))
    end

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call({:send_frame, cmd, req_id, body}, _from, {parent, script} = state) do
      send(parent, {:bot_frame, cmd, req_id, body})

      reply =
        case Map.get(script, cmd) do
          nil -> {:ok, %{"headers" => %{"req_id" => req_id}, "errcode" => 0, "body" => %{}}}
          fun when is_function(fun, 2) -> fun.(req_id, body)
        end

      {:reply, reply, state}
    end
  end

  defp setup_chat_binding do
    setup_wecom_config_registry()

    config_id = "wecom-outbox-#{System.unique_integer([:positive])}"
    bot_id = "bot-#{System.unique_integer([:positive])}"
    config = %{"botId" => bot_id, "secret" => "secret"}

    {:ok, _config} = AppConfigure.put_global_by_key(Config.chat_config_key(config_id), config)

    %{principal: agent} = agent_fixture()

    {:ok, binding} =
      SignalsGateway.upsert_binding(%{
        agent_uid: agent.uid,
        name: "wecom-outbox",
        adapter: "wecom",
        config_ref: "app-config://#{Config.chat_config_key(config_id)}",
        filters: %{},
        unaddressed_group_message_policy: :ignore
      })

    {binding, config}
  end

  defp setup_wecom_config_registry do
    AppConfigureRegistry.clear_for_test()
    AppConfigureCache.clear_for_test()
    :ok = AppConfigure.register_patterns(WeComAdapter.app_config_patterns())
  end

  defp start_fake_client(config, script \\ %{}) do
    registry = Ankole.Plugins.WeComAdapter.ConnectionRegistry

    if is_nil(Process.whereis(registry)) do
      start_supervised!({Registry, keys: :unique, name: registry})
    end

    key = Config.connection_key(config)

    start_supervised!(%{
      id: {:fake_bot, key},
      start: {FakeBotClient, :start_link, [key, self(), script]}
    })
  end

  defp outbox_entry(binding, attrs) do
    struct!(
      %OutboxEntry{
        agent_uid: binding.agent_uid,
        binding_name: binding.name,
        outbound_key: "test-key-#{System.unique_integer([:positive])}",
        signal_channel_id: "wecom:wr-g1",
        operation: :post,
        payload: %{},
        fallback_visible_text: "hello"
      },
      attrs
    )
  end

  test "post prefers the respond anchor and falls back to proactive send when absent" do
    {binding, config} = setup_chat_binding()
    start_fake_client(config)

    fresh_at = DateTime.to_iso8601(DateTime.utc_now())

    seed_channel("wecom:anchored", %{
      kind: :im_group,
      metadata: %{"last_req_id" => "req-anchor", "last_req_at" => fresh_at}
    })

    assert {:ok, result} =
             Outbox.send(outbox_entry(binding, signal_channel_id: "wecom:anchored"))

    assert_receive {:bot_frame, "aibot_respond_msg", "req-anchor", body}
    assert body["msgtype"] == "markdown"
    assert body["markdown"]["content"] == "hello"
    assert is_binary(result.created_source_entry_id)

    seed_channel("wecom:unanchored", %{kind: :im_group, metadata: %{}})

    assert {:ok, _result} =
             Outbox.send(outbox_entry(binding, signal_channel_id: "wecom:unanchored"))

    assert_receive {:bot_frame, "aibot_send_msg", _req_id, send_body}
    assert send_body["chatid"] == "unanchored"
    assert send_body["chat_type"] == 2
  end

  test "provider ack errors classify for the outbox retry policy" do
    {binding, config} = setup_chat_binding()

    start_fake_client(config, %{
      "aibot_send_msg" => fn req_id, _body ->
        {:error,
         WeComOpenAPI.Error.from_ack(%{
           "headers" => %{"req_id" => req_id},
           "errcode" => 45_009,
           "errmsg" => "freq out of limit"
         })}
      end
    })

    seed_channel("wecom:limited", %{kind: :im_group, metadata: %{}})

    assert {:error, {:reply_delivery, :retryable, %{reason: :rate_limited, code: 45_009}}} =
             Outbox.send(outbox_entry(binding, signal_channel_id: "wecom:limited"))
  end

  test "deterministic provider rejection is permanent" do
    {binding, config} = setup_chat_binding()

    start_fake_client(config, %{
      "aibot_send_msg" => fn req_id, _body ->
        {:error,
         WeComOpenAPI.Error.from_ack(%{
           "headers" => %{"req_id" => req_id},
           "errcode" => 40_201,
           "errmsg" => "message blocked by anti-spam policy"
         })}
      end
    })

    seed_channel("wecom:blocked", %{kind: :im_group, metadata: %{}})

    assert {:error, {:reply_delivery, :permanent, %{reason: 40_201, code: 40_201}}} =
             Outbox.send(outbox_entry(binding, signal_channel_id: "wecom:blocked"))
  end

  test "a card operation renders a button_interaction card with packed keys" do
    {binding, config} = setup_chat_binding()
    start_fake_client(config)

    seed_channel("wecom:cardch", %{
      kind: :im_group,
      metadata: %{
        "last_req_id" => "req-card",
        "last_req_at" => DateTime.to_iso8601(DateTime.utc_now())
      }
    })

    outbox =
      outbox_entry(binding,
        signal_channel_id: "wecom:cardch",
        operation: :card,
        payload: %{
          "interactive_output" => %{
            "interaction_id" => "int-1",
            "control_id" => "choice",
            "source_actor_event_id" => "evt-77",
            "version" => 3,
            "body" => "选择一个方向",
            "choices" => [
              %{"id" => "opt-a", "label" => "方案 A", "value" => "a"},
              %{"id" => "opt-b", "label" => "方案 B", "value" => "b"}
            ]
          }
        },
        fallback_visible_text: "选择一个方向：方案 A / 方案 B"
      )

    assert {:ok, result} = Outbox.send(outbox)
    assert result.created_source_entry_id == "ankole:evt-77"

    assert_receive {:bot_frame, "aibot_respond_msg", "req-card", body}
    assert body["msgtype"] == "template_card"
    card = body["template_card"]
    assert card["card_type"] == "button_interaction"
    assert card["task_id"] == "ankole:evt-77"

    assert [%{"text" => "方案 A", "key" => "ank1|int-1|3|choice|opt-a|a"}, _b] =
             card["button_list"]
  end

  test "a settled interaction card degrades to the fallback text" do
    output = %{
      "interaction_id" => "int-1",
      "control_id" => "choice",
      "source_actor_event_id" => "evt-77",
      "version" => 3,
      "state" => "answered",
      "choices" => [%{"id" => "opt-a", "label" => "方案 A"}]
    }

    outbox = %OutboxEntry{
      agent_uid: "a",
      binding_name: "b",
      outbound_key: "k",
      payload: %{"interactive_output" => output},
      fallback_visible_text: "已选择方案 A"
    }

    assert :fallback = TemplateCard.render(output, outbox)
  end

  test "media without a respond anchor fails with no_reply_anchor" do
    {binding, config} = setup_chat_binding()
    start_fake_client(config)
    seed_channel("wecom:mediach", %{kind: :im_group, metadata: %{}})

    outbox =
      outbox_entry(binding,
        signal_channel_id: "wecom:mediach",
        operation: :post,
        payload: %{
          "attachments" => [%{"name" => "a.png", "user_files_relative_path" => "x/a.png"}]
        }
      )

    assert {:error, :no_reply_anchor} = Outbox.send(outbox)
  end

  # --- identity provider -----------------------------------------------------

  defp identity_config(overrides \\ %{}) do
    Map.merge(
      %{
        "corpId" => "ww-corp-#{System.unique_integer([:positive])}",
        "agentId" => "1000002",
        "appSecret" => "app-secret",
        "contactsSecret" => "contacts-secret",
        "oidc" => %{"enabled" => true},
        "sync" => %{"contacts" => true}
      },
      overrides
    )
  end

  defp stub_qyapi(parent, responder) do
    Req.default_options(
      plug: fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        if conn.request_path == "/cgi-bin/gettoken" do
          Req.Test.json(conn, %{
            "errcode" => 0,
            "access_token" => "tok-#{conn.query_params["corpsecret"]}",
            "expires_in" => 7200
          })
        else
          send(parent, {:qyapi, conn.request_path, conn.query_params})
          responder.(conn)
        end
      end
    )
  end

  test "authorization_url builds the WWLogin page and fails closed when disabled" do
    config = identity_config()

    assert {:ok, url} =
             IdentityProvider.authorization_url(config,
               redirect_uri: "https://ankole.example/sessions/oidc/wecom/callback",
               state: "st-1"
             )

    assert url =~ "login_type=CorpApp"
    assert url =~ "agentid=1000002"

    disabled = identity_config(%{"oidc" => %{"enabled" => false}})

    assert {:error, :oidc_disabled} =
             IdentityProvider.authorization_url(disabled, redirect_uri: "https://x", state: "s")
  end

  test "the login chain resolves the code to a userid hydrated from the contacts secret" do
    stub_qyapi(self(), fn conn ->
      case conn.request_path do
        "/cgi-bin/auth/getuserinfo" ->
          assert conn.query_params["code"] == "code-1"
          Req.Test.json(conn, %{"errcode" => 0, "userid" => "alice"})

        "/cgi-bin/user/get" ->
          assert conn.query_params["userid"] == "alice"
          # Hydration must ride the contacts-sync token, not the app token.
          assert conn.query_params["access_token"] == "tok-contacts-secret"

          Req.Test.json(conn, %{
            "errcode" => 0,
            "userid" => "alice",
            "name" => "Alice",
            "department" => [2]
          })
      end
    end)

    assert {:ok, %{user: user}} = IdentityProvider.exchange_code(identity_config(), "code-1")
    assert user["userid"] == "alice"
    assert user["name"] == "Alice"
  end

  test "non-members fail the login closed and hydration failure keeps the bare userid" do
    stub_qyapi(self(), fn conn ->
      case conn.request_path do
        "/cgi-bin/auth/getuserinfo" ->
          Req.Test.json(conn, %{"errcode" => 0, "openid" => "o-1"})
      end
    end)

    assert {:error, :non_member} = IdentityProvider.exchange_code(identity_config(), "code-x")

    stub_qyapi(self(), fn conn ->
      case conn.request_path do
        "/cgi-bin/auth/getuserinfo" ->
          Req.Test.json(conn, %{"errcode" => 0, "userid" => "bob"})

        "/cgi-bin/user/get" ->
          Req.Test.json(conn, %{"errcode" => 60_011, "errmsg" => "no privilege"})
      end
    end)

    assert {:ok, %{user: %{"userid" => "bob"} = user}} =
             IdentityProvider.exchange_code(identity_config(), "code-2")

    refute Map.has_key?(user, "name")
  end

  test "credential check surfaces the trusted-IP rejection with its console fix" do
    stub_qyapi(self(), fn _conn -> flunk("no non-token call expected") end)

    Req.default_options(
      plug: fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        case conn.query_params["corpsecret"] do
          "app-secret" ->
            Req.Test.json(conn, %{"errcode" => 0, "access_token" => "t", "expires_in" => 7200})

          "contacts-secret" ->
            Req.Test.json(conn, %{
              "errcode" => 60_020,
              "errmsg" => "not allow to access from your ip"
            })
        end
      end
    )

    assert {:error, {:trusted_ip_rejected, :contacts_secret, message}} =
             IdentityProvider.check_credentials(identity_config())

    assert message =~ "Contacts sync"
  end

  test "full directory sync builds department groups and de-duplicates multi-department users" do
    provider_id = "wecom-idp-#{System.unique_integer([:positive])}"

    stub_qyapi(self(), fn conn ->
      case conn.request_path do
        "/cgi-bin/department/list" ->
          Req.Test.json(conn, %{
            "errcode" => 0,
            "department" => [
              %{"id" => 1, "parentid" => 0, "name" => "ACME"},
              %{"id" => 2, "parentid" => 1, "name" => "Engineering"},
              %{"id" => 3, "parentid" => 2, "name" => "Platform"}
            ]
          })

        "/cgi-bin/user/list" ->
          case conn.query_params["department_id"] do
            "1" ->
              Req.Test.json(conn, %{"errcode" => 0, "userlist" => []})

            "2" ->
              Req.Test.json(conn, %{
                "errcode" => 0,
                "userlist" => [
                  %{
                    "userid" => "alice",
                    "name" => "Alice",
                    "department" => [2, 3],
                    "biz_mail" => "alice@acme.example",
                    "position" => "Engineer",
                    "status" => 1
                  }
                ]
              })

            "3" ->
              Req.Test.json(conn, %{
                "errcode" => 0,
                "userlist" => [
                  %{"userid" => "alice", "name" => "Alice", "department" => [2, 3]},
                  %{"userid" => "bob", "name" => "Bob", "department" => [3]}
                ]
              })
          end
      end
    end)

    assert {:ok, %{users: 2, departments: 3}} =
             IdentityProvider.sync_directory(provider_id, identity_config())

    assert [_group_id] = Ankole.AuthZ.external_group_ids(provider_id, :directory_department, "2")

    assert {:ok, principal} = Ankole.Principals.resolve_platform_subject(provider_id, "alice")
    assert principal.display_name == "Alice"

    human_user = Repo.get!(Ankole.Principals.HumanUser, principal.uid)
    assert human_user.email == "alice@acme.example"
  end

  test "directory sync without the contacts secret reports the missing requirement" do
    config = identity_config(%{"contactsSecret" => nil, "sync" => %{"contacts" => false}})
    assert {:error, :contacts_secret_required} = IdentityProvider.sync_directory("p-1", config)
  end
end
