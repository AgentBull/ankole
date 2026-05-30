defmodule BullX.Integration.IMGateway.IdentityRoutingTest do
  @moduledoc """
  Family H — principal resolution and authorization at the IM boundary.
  """
  use BullX.Integration.IMGateway.Case

  setup do
    MockLLM.set_responder(fn _req -> {:text, "ok reply"} end)
    :ok
  end

  test "H: an addressed message from an unauthorized user is denied (no reply)" do
    # :eve is not in the provisioned/granted set, so she has no invoke grant.
    chat = new_dm(with: :eve)
    say(chat, :eve, "let me in")
    settle()

    assert Repo.exists?(
             from(m in BullX.IMGateway.Message,
               where: m.lifecycle_state == :active and m.text == "let me in"
             )
           )

    assert Repo.exists?(
             from(e in Entry,
               where: fragment("?->>'type' = 'bullx.message.received'", e.cloud_event)
             )
           )

    assert %Message{
             role: :assistant,
             kind: :error,
             metadata: %{"safe_error_code" => "acl_denied"}
           } = Repo.one!(from(m in Message, where: m.role == :assistant and m.kind == :error))

    assert transcript(chat) == []
    assert MockLLM.call_count() == 0
  end

  test "H1: provisioning and granting a new user lets the bot answer them", %{
    agent_uid: agent_uid
  } do
    provision_user!(:frank, agent_uid)

    chat = new_dm(with: :frank)
    say(chat, :frank, "hello bot")
    settle()

    assert last_bot_text(chat) == "ok reply"
  end

  test "H: repeated messages from one external user reuse a single conversation" do
    chat = new_dm(with: :alice)
    say(chat, :alice, "first")
    settle()
    say(chat, :alice, "second")
    settle()

    assert Repo.aggregate(from(c in Conversation), :count) == 1
    assert MockLLM.call_count() == 2
  end

  test "H2: the same external account id in different sources does not share context", %{
    agent_uid: agent_uid
  } do
    source = "secondary"

    delivery_rule!(agent_uid,
      name: "mock-route-secondary",
      match_expr: ~s(channel.adapter == "mock" && channel.id == "#{source}")
    )

    provision_user!(:alice, agent_uid, source_id: source)

    default_chat = new_dm(id: "shared-provider-dm", source_id: "default", with: :alice)
    secondary_chat = new_dm(id: "shared-provider-dm", source_id: source, with: :alice)

    say(default_chat, :alice, "default source secret")
    settle()

    say(secondary_chat, :alice, "secondary source question")
    settle()

    assert Repo.aggregate(from(c in Conversation), :count) == 2
    assert MockLLM.call_count() == 2

    [_first, second] = Enum.map(MockLLM.requests(), &MockLLM.prompt_text/1)
    assert second =~ "secondary source question"
    refute second =~ "default source secret"
  end

  test "H3: multiple bot sources observing the same group share one IM projection without losing fanout",
       %{
         agent_uid: primary_agent_uid
       } do
    secondary = create_agent!("im-gateway-integration-agent-secondary")

    delivery_rule!(secondary.uid,
      name: "mock-route-secondary-observe",
      match_expr: ~s(channel.adapter == "mock" && channel.id == "secondary")
    )

    provision_user!(:alice, secondary.uid, source_id: "secondary")

    default_chat = new_group(id: "shared-group", source_id: "default", mode: "observe_all")
    secondary_chat = new_group(id: "shared-group", source_id: "secondary", mode: "observe_all")

    say(default_chat, :alice, "shared context", message_id: "shared-message")
    say(secondary_chat, :alice, "shared context", message_id: "shared-message")
    settle()

    assert Repo.aggregate(from(r in BullX.IMGateway.Room), :count) == 1
    assert Repo.aggregate(from(m in BullX.IMGateway.Message), :count) == 1

    assert Repo.aggregate(
             from(e in Entry,
               where: fragment("?->>'type' = 'bullx.message.received'", e.cloud_event)
             ),
             :count
           ) == 2

    assert Repo.aggregate(from(c in Conversation), :count) == 2

    assert Repo.aggregate(
             from(m in Message,
               where: m.role == :im_ambient and m.kind == :normal
             ),
             :count
           ) == 2

    agent_uids = Repo.all(from(c in Conversation, select: c.agent_uid))
    assert Enum.sort(agent_uids) == Enum.sort([primary_agent_uid, secondary.uid])
    assert MockLLM.call_count() == 0
  end
end
