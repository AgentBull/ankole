defmodule Ankole.PrincipalsTest do
  use Ankole.DataCase, async: true

  alias Ankole.Principals
  alias Ankole.Principals.ExternalIdentity

  import Ankole.PrincipalsFixtures

  describe "humans" do
    test "create_human/1 creates a Principal and optional human profile" do
      assert {:ok, %{principal: principal, human_user: human_user}} =
               Principals.create_human(%{
                 uid: " Alice ",
                 display_name: " Alice ",
                 avatar_url: " https://example.com/alice.png ",
                 email: " ALICE@Example.COM ",
                 mobile: " +1 415 555 2671 ",
                 job_title: " Research Lead "
               })

      assert principal.uid == "alice"
      assert principal.type == :human
      assert principal.status == :active
      assert principal.display_name == "Alice"
      assert principal.avatar_url == "https://example.com/alice.png"
      assert human_user.principal_uid == "alice"
      assert human_user.email == "alice@example.com"
      assert human_user.mobile == "+14155552671"
      assert human_user.job_title == "Research Lead"
    end

    test "create_human/1 rejects malformed optional contact fields" do
      assert {:error, changeset} =
               Principals.create_human(%{
                 uid: unique_uid("bad-human"),
                 email: "not-email",
                 mobile: "12345"
               })

      assert %{email: [_], mobile: [_]} = errors_on(changeset)
    end

    test "update_human/2 preserves omitted profile fields and clears explicit nil" do
      %{principal: principal, human_user: human_user} =
        human_fixture(%{
          uid: unique_uid("profile-human"),
          email: "profile@example.com",
          mobile: "+14155550000",
          job_title: "Operator"
        })

      assert {:ok, %{principal: updated_principal, human_user: updated_human}} =
               Principals.update_human(principal.uid, %{
                 display_name: "Updated",
                 job_title: nil
               })

      assert updated_principal.display_name == "Updated"
      assert updated_human.email == human_user.email
      assert updated_human.mobile == human_user.mobile
      assert updated_human.job_title == nil
    end
  end

  describe "agents" do
    test "create_agent/1 creates an agent Principal with AI Colleague defaults" do
      assert {:ok, %{principal: principal, agent: agent}} =
               Principals.create_agent(%{
                 uid: " Research-Agent ",
                 display_name: "Research Agent",
                 role: " Research Analyst "
               })

      assert principal.uid == "research-agent"
      assert principal.type == :agent
      assert principal.status == :active
      assert agent.uid == principal.uid
      assert agent.type == :ai_colleague
      assert agent.role == "Research Analyst"
      assert agent.options == %{}
    end

    test "create_agent/1 requires role and object options" do
      assert {:error, role_changeset} =
               Principals.create_agent(%{
                 uid: unique_uid("roleless-agent"),
                 role: " "
               })

      assert %{role: [_]} = errors_on(role_changeset)

      assert {:error, options_changeset} =
               Principals.create_agent(%{
                 uid: unique_uid("bad-options-agent"),
                 role: "Research Analyst",
                 options: "not-a-map"
               })

      assert %{options: [_]} = errors_on(options_changeset)
    end

    test "create_agent/1 normalizes created_by_principal_uid" do
      %{principal: creator} = human_fixture(%{uid: unique_uid("agent-creator")})

      assert {:ok, %{agent: agent}} =
               Principals.create_agent(%{
                 uid: unique_uid("created-agent"),
                 role: "Research Analyst",
                 created_by_principal_uid: String.upcase(creator.uid)
               })

      assert agent.created_by_principal_uid == creator.uid
    end

    test "update_agent/2 updates mutable agent fields without changing uid" do
      %{principal: principal} = agent_fixture(%{uid: unique_uid("mutable-agent")})

      assert {:ok, %{principal: updated_principal, agent: updated_agent}} =
               Principals.update_agent(principal.uid, %{
                 uid: "ignored",
                 display_name: "New Name",
                 role: "Customer Success Operator",
                 options: %{"temperature" => 0.2}
               })

      assert updated_principal.uid == principal.uid
      assert updated_principal.display_name == "New Name"
      assert updated_agent.uid == principal.uid
      assert updated_agent.role == "Customer Success Operator"
      assert updated_agent.options == %{"temperature" => 0.2}
    end

    test "list_active_agents/0 excludes disabled agents" do
      active = agent_fixture(%{uid: unique_uid("active-agent")})
      disabled = agent_fixture(%{uid: unique_uid("disabled-agent")})

      assert {:ok, _principal} = Principals.disable_principal(disabled.principal.uid)

      assert Enum.any?(
               Principals.list_active_agents(),
               &(&1.principal.uid == active.principal.uid)
             )

      refute Enum.any?(
               Principals.list_active_agents(),
               &(&1.principal.uid == disabled.principal.uid)
             )
    end
  end

  describe "platform subjects" do
    test "upsert_platform_subject_human/1 converges repeated observations on one Principal" do
      assert {:ok, first} =
               Principals.upsert_platform_subject_human(%{
                 provider: "lark-main",
                 external_id: "ou_user_1",
                 uid: "Alice",
                 display_name: "Alice",
                 email: "alice@example.com",
                 metadata: %{"tenant_key" => "tenant_a"}
               })

      assert first.principal.uid == "alice"
      assert first.identity.kind == :platform_subject
      assert first.identity.provider == "lark-main"
      assert first.identity.external_id == "ou_user_1"

      assert {:ok, second} =
               Principals.upsert_platform_subject_human(%{
                 provider: "lark-main",
                 external_id: "ou_user_1",
                 uid: "ignored-new-uid",
                 display_name: "Alice Updated",
                 metadata: %{"open_id" => "open_1"}
               })

      assert second.principal.uid == first.principal.uid
      assert second.principal.display_name == "Alice Updated"
      assert second.human_user.email == "alice@example.com"
      assert second.identity.metadata["tenant_key"] == "tenant_a"
      assert second.identity.metadata["open_id"] == "open_1"
      assert second.identity.metadata["provider"] == "lark-main"
      assert second.identity.metadata["external_id"] == "ou_user_1"
    end

    test "resolve_platform_subject/2 returns only active humans" do
      %{principal: principal, identity: identity} = platform_subject_fixture()

      assert {:ok, ^principal} =
               Principals.resolve_platform_subject("lark-main", identity.external_id)

      assert {:ok, _disabled} = Principals.disable_principal(principal.uid)

      assert {:error, :principal_disabled} =
               Principals.resolve_platform_subject("lark-main", identity.external_id)
    end

    test "upsert_platform_subject_human/1 refuses to bind a subject to an Agent UID" do
      %{principal: principal} = agent_fixture(%{uid: unique_uid("agent-subject")})

      assert {:error, :not_human} =
               Principals.upsert_platform_subject_human(%{
                 provider: "lark-main",
                 external_id: "ou_agent_subject",
                 uid: principal.uid
               })
    end
  end

  describe "channel actors" do
    test "resolve_channel_actor/3 fails closed until the binding is verified" do
      %{principal: principal} = human_fixture()

      unverified =
        channel_actor_identity_fixture(%{
          human: %{principal: principal},
          adapter: "lark",
          channel_id: "chat_a",
          external_id: "user_a"
        })

      refute Principals.channel_identity_verified?(unverified)

      assert {:error, :identity_unverified} =
               Principals.resolve_channel_actor("lark", "chat_a", "user_a")

      verified =
        channel_actor_identity_fixture(%{
          human: %{principal: principal},
          adapter: "lark",
          channel_id: "chat_b",
          external_id: "user_b",
          verified_at: DateTime.utc_now(:microsecond)
        })

      assert Principals.channel_identity_verified?(verified)
      assert {:ok, ^principal} = Principals.resolve_channel_actor("lark", "chat_b", "user_b")
    end

    test "external identity changeset enforces provider and channel shapes" do
      %{principal: principal} = human_fixture()

      assert {:error, provider_subject_changeset} =
               Principals.create_external_identity(%{
                 principal_uid: principal.uid,
                 kind: :platform_subject,
                 provider: "lark-main",
                 adapter: "lark",
                 external_id: "ou_bad",
                 metadata: %{}
               })

      assert %{adapter: [_]} = errors_on(provider_subject_changeset)

      assert {:error, channel_actor_changeset} =
               Principals.create_external_identity(%{
                 principal_uid: principal.uid,
                 kind: :channel_actor,
                 provider: "lark-main",
                 adapter: "lark",
                 channel_id: "chat_bad",
                 external_id: "open_bad",
                 metadata: %{}
               })

      assert %{provider: [_]} = errors_on(channel_actor_changeset)
    end

    test "external identity writes normalize principal_uid" do
      %{principal: principal} = human_fixture(%{uid: unique_uid("identity-owner")})

      assert {:ok, identity} =
               Principals.create_external_identity(%{
                 principal_uid: String.upcase(principal.uid),
                 kind: :channel_actor,
                 adapter: "lark",
                 channel_id: unique_uid("chat"),
                 external_id: unique_uid("actor"),
                 metadata: %{}
               })

      assert identity.principal_uid == principal.uid
    end

    test "upsert_external_identity/1 converges on the natural identity key" do
      first = human_fixture(%{uid: unique_uid("first-owner")})
      second = human_fixture(%{uid: unique_uid("second-owner")})
      channel_id = unique_uid("chat")
      external_id = unique_uid("actor")

      assert {:ok, inserted} =
               Principals.upsert_external_identity(%{
                 principal_uid: first.principal.uid,
                 kind: :channel_actor,
                 adapter: "lark",
                 channel_id: channel_id,
                 external_id: external_id,
                 verified_at: DateTime.utc_now(:microsecond),
                 metadata: %{"source" => "first"}
               })

      assert {:ok, updated} =
               Principals.upsert_external_identity(%{
                 principal_uid: String.upcase(second.principal.uid),
                 kind: :channel_actor,
                 adapter: "lark",
                 channel_id: channel_id,
                 external_id: external_id,
                 verified_at: DateTime.utc_now(:microsecond),
                 metadata: %{"source" => "second"}
               })

      assert updated.id == inserted.id
      assert updated.principal_uid == second.principal.uid
      assert updated.metadata == %{"source" => "second"}
    end

    test "create_external_identity/1 stores UUIDv7 ids for binding rows" do
      identity = channel_actor_identity_fixture()

      assert %ExternalIdentity{} = identity

      assert identity.id =~
               ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
    end
  end
end
