defmodule Ankole.E2E.SlackLifecycleTest do
  use Ankole.DataCase, async: false

  alias Ankole.AuthZ
  alias Ankole.AuthZ.Membership
  alias Ankole.E2E.FakeSlack.Server

  alias Ankole.Plugins.SlackAdapter.Channels
  alias Ankole.Plugins.SlackAdapter.Config
  alias Ankole.Plugins.SlackAdapter.ConnectionReconciler
  alias Ankole.Plugins.SlackAdapter.IdentityProvider
  alias Ankole.Plugins.SlackAdapter.Inbound

  alias Ankole.Principals
  alias Ankole.OIDCClientFixture
  alias Ankole.Repo

  alias Ankole.Conversations.AdapterContext
  alias Ankole.Signals.BindingMembership
  alias Ankole.Conversations.Conversation
  alias Ankole.Conversations.External
  alias SlackOpenAPI.Event

  import Ankole.E2E.Harness, only: [put_slack_test_client_opts!: 1]
  import Ankole.PrincipalsFixtures

  test "directory sync creates users, usergroups and memberships, while OIDC converges on the same subject" do
    config = %{
      "clientID" => "client",
      "clientSecret" => "secret",
      "botToken" => "xoxb-fake",
      "appToken" => "xapp-fake",
      "oidc" => %{"enabled" => true, "scopes" => ["openid", "profile", "email"]},
      "sync" => %{"contacts" => true, "websocket" => true, "pageSize" => 200}
    }

    nonce = Ecto.UUID.generate()
    state = Ecto.UUID.generate()
    code = Ecto.UUID.generate()
    redirect_uri = "https://ankole.test/callback"

    assert {:ok, authorization_url} =
             IdentityProvider.authorization_url(config,
               redirect_uri: redirect_uri,
               state: state,
               nonce: nonce
             )

    assert %URI{
             scheme: "https",
             host: "slack.com",
             path: "/openid/connect/authorize",
             query: query
           } =
             URI.parse(authorization_url)

    authorization = URI.decode_query(query)

    assert authorization == %{
             "client_id" => config["clientID"],
             "redirect_uri" => redirect_uri,
             "response_type" => "code",
             "scope" => "openid profile email",
             "state" => state,
             "nonce" => nonce
           }

    {id_token, jwks} =
      OIDCClientFixture.token("https://slack.com", config["clientID"], %{
        "sub" => "U1",
        "nonce" => authorization["nonce"]
      })

    fake =
      Server.start!(
        users: [
          %{
            "id" => "U1",
            "name" => "Ada",
            "real_name" => "Ada Lovelace",
            "profile" => %{"email" => "ada@example.com", "title" => "Engineer"}
          },
          %{"id" => "U2", "name" => "Grace", "profile" => %{"email" => "grace@example.com"}},
          %{"id" => "UBOT2", "name" => "Other Bot", "is_bot" => true}
        ],
        usergroups: [
          %{
            "id" => "S1",
            "name" => "Engineering",
            "handle" => "engineering",
            "user_count" => 1,
            "users" => ["U1"],
            "date_delete" => 0
          }
        ],
        oidc: %{
          client_id: authorization["client_id"],
          client_secret: config["clientSecret"],
          code: code,
          redirect_uri: authorization["redirect_uri"],
          scope: authorization["scope"],
          access_token: "xoxp-slack-lifecycle",
          id_token: id_token,
          jwks: jwks,
          user_info: %{
            "sub" => "U1",
            "https://slack.com/user_id" => "U1",
            "https://slack.com/team_id" => "TFAKE",
            "email" => "ada@example.com",
            "name" => "Ada"
          }
        }
      )

    put_slack_test_client_opts!(base_url: fake.base_url, req_options: [plug: nil])
    previous = Req.default_options()
    parent = self()

    # Keep the public issuer while its discovery transport reaches FakeSlack.
    # Token and UserInfo requests already use its real HTTP client endpoint.
    Req.default_options(
      Keyword.put(previous, :plug, fn conn ->
        assert conn.scheme == :https
        assert conn.host == "slack.com"
        assert conn.request_path in ["/.well-known/openid-configuration", "/openid/connect/keys"]

        response =
          Req.get!("http://127.0.0.1:#{fake.port}" <> conn.request_path,
            plug: nil,
            raw: true,
            retry: false,
            redirect: false
          )

        send(parent, {:slack_oidc_http, conn.request_path})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(response.status, response.body)
      end)
    )

    on_exit(fn -> Req.default_options(previous) end)

    assert {:ok, %{users: 2, usergroups: 1}} =
             IdentityProvider.sync_directory("slack-main", config)

    assert {:ok, uid} = Principals.resolve_platform_subject_uid("slack-main", "U1")
    assert {:ok, principal} = Principals.get_principal(uid)
    assert principal.display_name == "Ada Lovelace"

    [group_id] = AuthZ.external_group_ids("slack-main", :directory_department, "S1")
    assert Repo.get_by(Membership, principal_uid: uid, group_id: group_id)

    assert {:ok, %{token: token, user: %{"user_id" => "U1"} = login_user}} =
             IdentityProvider.exchange_code(config, code,
               redirect_uri: redirect_uri,
               nonce: nonce
             )

    assert token.raw["scope"] == authorization["scope"]
    assert_received {:slack_oidc_http, "/.well-known/openid-configuration"}
    assert_received {:slack_oidc_http, "/openid/connect/keys"}

    assert {:ok, login_observed} = IdentityProvider.upsert_user("slack-main", login_user)
    assert login_observed.principal.uid == uid
    assert Repo.get_by(Membership, principal_uid: uid, group_id: group_id)
  end

  test "binding lifecycle projects joined channels, filters bots, applies member events, and clears when the bot leaves" do
    fake =
      Server.start!(
        users: [
          %{"id" => "U1", "name" => "Ada"},
          %{"id" => "UBOT", "name" => "Ankole", "is_bot" => true}
        ],
        channels: [
          %{"id" => "C1", "name" => "engineering", "is_im" => false, "is_private" => false}
        ],
        members: %{"C1" => ["U1", "UBOT"]}
      )

    put_slack_test_client_opts!(base_url: fake.base_url)

    %{principal: agent} = agent_fixture()
    binding_name = "slack-lifecycle"

    config = %{
      "botToken" => "xoxb-fake",
      "appToken" => "xapp-fake",
      "userName" => "Slack"
    }

    on_exit(fn -> ConnectionReconciler.stop(Config.connection_key(config)) end)

    assert {:ok, _binding} =
             Ankole.Signals.Bindings.put_binding(agent.uid, "slack", binding_name, %{
               "config" => config,
               "unmatched_sender_policy" => "create_standalone"
             })

    assert {:ok, %{synced_channels: 1, marked_left: 0}} =
             Channels.sync_binding(agent.uid, binding_name)

    assert %Conversation{principal_group_id: group_id} =
             External.get_conversation(Repo, "slack:C1")

    assert {:ok, group} = AuthZ.get_principal_group(group_id)
    assert BindingMembership.joined?(group.metadata, agent.uid, binding_name)
    assert {:ok, u1_uid} = Principals.resolve_platform_subject_uid("slack-main", "U1")
    assert Repo.get_by(Membership, principal_uid: u1_uid, group_id: group_id)
    assert {:error, :not_found} = Principals.resolve_platform_subject_uid("slack-main", "UBOT")

    context =
      AdapterContext.new(
        agent_uid: agent.uid,
        binding_name: binding_name,
        adapter: "slack",
        user_name: "Slack"
      )

    assert {:ok, runtime_config} = Config.resolve_runtime_bot_identity(config)
    consumer = Inbound.chat_consumer(context, runtime_config)

    joined = %Event{
      type: "member_joined_channel",
      content: %{"channel" => "C1", "user" => "U2"},
      raw: %{}
    }

    assert {:ok, [%{status: :member_added, principal_uid: u2_uid}]} =
             Channels.handle_im_event("member_joined_channel", joined, [consumer])

    assert Repo.get_by(Membership, principal_uid: u2_uid, group_id: group_id)

    bot_left = %Event{
      type: "member_left_channel",
      content: %{"channel" => "C1", "user" => "UBOT"},
      raw: %{}
    }

    assert {:ok, [%{status: :all_participants_left}]} =
             Channels.handle_im_event("member_left_channel", bot_left, [consumer])

    assert {:ok, group} = AuthZ.get_principal_group(group_id)
    refute BindingMembership.joined?(group.metadata, agent.uid, binding_name)
    refute Repo.get_by(Membership, principal_uid: u1_uid, group_id: group_id)
    refute Repo.get_by(Membership, principal_uid: u2_uid, group_id: group_id)
  end
end
