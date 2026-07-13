defmodule Ankole.E2E.SlackLifecycleTest do
  use Ankole.DataCase, async: false

  alias Ankole.AppConfigure
  alias Ankole.AuthZ
  alias Ankole.AuthZ.Membership
  alias Ankole.E2E.FakeSlack.Server
  alias Ankole.Plugins.SlackAdapter.{Channels, Config, IdentityProvider, Inbound}
  alias Ankole.Principals
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.{AdapterContext, BindingMembership, Channel}
  alias SlackOpenAPI.Event

  import Ankole.PrincipalsFixtures

  test "directory sync creates users, usergroups and memberships, while OIDC converges on the same subject" do
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
        ]
      )

    config = %{
      "clientID" => "client",
      "clientSecret" => "secret",
      "botToken" => "xoxb-fake",
      "appToken" => "xapp-fake",
      "baseURL" => fake.base_url,
      "oidc" => %{"enabled" => true, "scopes" => ["openid", "profile", "email"]},
      "sync" => %{"contacts" => true, "websocket" => true, "pageSize" => 200}
    }

    assert {:ok, %{users: 2, usergroups: 1}} =
             IdentityProvider.sync_directory("slack-main", config)

    assert {:ok, uid} = Principals.resolve_platform_subject_uid("slack-main", "U1")
    assert {:ok, principal} = Principals.get_principal(uid)
    assert principal.display_name == "Ada Lovelace"

    [group_id] = AuthZ.external_group_ids("slack-main", :directory_department, "S1")
    assert Repo.get_by(Membership, principal_uid: uid, group_id: group_id)

    assert {:ok, %{user: %{"user_id" => "U1"} = login_user}} =
             IdentityProvider.exchange_code(config, "code",
               redirect_uri: "https://ankole.test/callback"
             )

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

    %{principal: agent} = agent_fixture()
    binding_name = "slack-lifecycle"

    config = %{
      "botToken" => "xoxb-fake",
      "appToken" => "xapp-fake",
      "botUserID" => "UBOT",
      "baseURL" => fake.base_url,
      "platformSubjectNamespace" => "slack-main",
      "userName" => "Slack"
    }

    assert {:ok, _stored} =
             AppConfigure.put_global_by_key(Config.chat_config_key(binding_name), config)

    assert {:ok, _binding} =
             SignalsGateway.upsert_binding(%{
               agent_uid: agent.uid,
               name: binding_name,
               adapter: "slack",
               config_ref: "app-config://#{Config.chat_config_key(binding_name)}",
               filters: %{},
               unaddressed_group_message_policy: :ignore
             })

    assert {:ok, %{synced_channels: 1, marked_left: 0}} =
             Channels.sync_binding(agent.uid, binding_name)

    assert %Channel{principal_group_id: group_id} = Repo.get(Channel, "slack:C1")
    assert {:ok, group} = AuthZ.get_principal_group(group_id)
    assert BindingMembership.joined?(group.metadata, agent.uid, binding_name)
    assert "slack:C1" in Enum.map(SignalsGateway.visible_channels(agent.uid), & &1.id)
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

    consumer = Inbound.chat_consumer(context, config)

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
    refute "slack:C1" in Enum.map(SignalsGateway.visible_channels(agent.uid), & &1.id)
    refute Repo.get_by(Membership, principal_uid: u1_uid, group_id: group_id)
    refute Repo.get_by(Membership, principal_uid: u2_uid, group_id: group_id)
  end
end
