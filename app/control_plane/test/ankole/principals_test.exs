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

  describe "principals" do
    test "list_active_principals/0 includes humans and agents in UID order and excludes disabled rows" do
      human = human_fixture(%{uid: unique_uid("z-active-human")})
      agent = agent_fixture(%{uid: unique_uid("a-active-agent")})
      disabled = human_fixture(%{uid: unique_uid("m-disabled-human")})

      assert {:ok, _principal} = Principals.disable_principal(disabled.principal.uid)

      principals = Principals.list_active_principals()
      listed_uids = Enum.map(principals, & &1.uid)

      assert human.principal.uid in listed_uids
      assert agent.principal.uid in listed_uids
      refute disabled.principal.uid in listed_uids
      assert listed_uids == Enum.sort(listed_uids)
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
      # The uid attr is the admission-binding path: it points the first-seen
      # subject at a Principal a human reviewer already matched.
      %{principal: existing} = human_fixture(%{uid: "alice", email: "alice@example.com"})

      assert {:ok, first} =
               Principals.upsert_platform_subject_human(%{
                 provider: "lark-main",
                 external_id: "ou_user_1",
                 uid: existing.uid,
                 display_name: "Alice",
                 metadata: %{"tenant_key" => "tenant_a"}
               })

      assert first.principal.uid == "alice"
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

    test "upsert_platform_subject_human/1 joins a first-seen subject to the email owner" do
      assert {:ok, slack} =
               Principals.upsert_platform_subject_human(%{
                 provider: "slack-main",
                 external_id: "U1000",
                 display_name: "Alice",
                 email: "join.alice@example.com"
               })

      # The same verified email converges the two providers; casing does not matter.
      assert {:ok, google} =
               Principals.upsert_platform_subject_human(%{
                 provider: "google-workspace-main",
                 external_id: "103200300400500600700",
                 display_name: "Alice G",
                 email: "Join.Alice@Example.com",
                 job_title: "Engineer"
               })

      assert google.principal.uid == slack.principal.uid
      assert google.identity.provider == "google-workspace-main"
      assert google.identity.external_id == "103200300400500600700"
      assert google.principal.display_name == "Alice G"
      assert google.human_user.job_title == "Engineer"

      assert {:ok, resolved} = Principals.resolve_platform_subject("slack-main", "U1000")
      assert resolved.uid == slack.principal.uid
    end

    test "upsert_platform_subject_human/1 lets the email claim win over a uid suggestion" do
      %{principal: bystander} = human_fixture(%{uid: unique_uid("bystander")})

      assert {:ok, owner} =
               Principals.upsert_platform_subject_human(%{
                 provider: "slack-main",
                 external_id: "U1500",
                 email: "claim.owner@example.com"
               })

      assert {:ok, joined} =
               Principals.upsert_platform_subject_human(%{
                 provider: "google-workspace-main",
                 external_id: "207300400500600700800",
                 uid: bystander.uid,
                 email: "claim.owner@example.com"
               })

      assert joined.principal.uid == owner.principal.uid
      refute joined.principal.uid == bystander.uid
    end

    test "upsert_platform_subject_human/1 keeps equal external ids from different providers apart" do
      assert {:ok, first} =
               Principals.upsert_platform_subject_human(%{
                 provider: "slack-main",
                 external_id: "12345",
                 display_name: "Slack Person"
               })

      assert {:ok, second} =
               Principals.upsert_platform_subject_human(%{
                 provider: "dingtalk-main",
                 external_id: "12345",
                 display_name: "DingTalk Person"
               })

      assert first.principal.uid == "slack-main:12345"
      assert second.principal.uid == "dingtalk-main:12345"

      assert {:ok, slack_resolved} = Principals.resolve_platform_subject("slack-main", "12345")
      assert {:ok, ding_resolved} = Principals.resolve_platform_subject("dingtalk-main", "12345")
      assert slack_resolved.uid == first.principal.uid
      assert ding_resolved.uid == second.principal.uid
    end

    test "upsert_platform_subject_human/1 drops a conflicting email from a bound subject" do
      assert {:ok, google} =
               Principals.upsert_platform_subject_human(%{
                 provider: "google-workspace-main",
                 external_id: "998877665544332211009",
                 email: "conflict.bob@example.com"
               })

      assert {:ok, slack_first} =
               Principals.upsert_platform_subject_human(%{
                 provider: "slack-main",
                 external_id: "U2000"
               })

      refute slack_first.principal.uid == google.principal.uid

      # A later directory sync attaches an email another principal already
      # owns: the update succeeds without the email instead of aborting.
      assert {:ok, slack_second} =
               Principals.upsert_platform_subject_human(%{
                 provider: "slack-main",
                 external_id: "U2000",
                 email: "conflict.bob@example.com",
                 job_title: "Support"
               })

      assert slack_second.principal.uid == slack_first.principal.uid
      assert slack_second.human_user.email == nil
      assert slack_second.human_user.job_title == "Support"
    end

    test "upsert_platform_subject_human/1 joins a first-seen subject by mobile" do
      assert {:ok, first} =
               Principals.upsert_platform_subject_human(%{
                 provider: "lark-main",
                 external_id: "ou_mobile_owner",
                 email: "mobile.owner@example.com",
                 mobile: "+14155559999"
               })

      assert {:ok, second} =
               Principals.upsert_platform_subject_human(%{
                 provider: "google-workspace-main",
                 external_id: "556677889900112233445",
                 email: "mobile.other@example.com",
                 mobile: "+1 415 555 9999"
               })

      assert second.principal.uid == first.principal.uid
    end
  end

  describe "match_platform_subject_human/1" do
    test "matches any candidate external id" do
      %{principal: principal, identity: identity} =
        platform_subject_fixture(%{provider: "lark-main"})

      assert {:ok, ^principal} =
               Principals.match_platform_subject_human(%{
                 provider: "lark-main",
                 external_ids: ["unknown_primary", identity.external_id]
               })
    end

    test "matches by email and then mobile when no candidate id is bound" do
      %{principal: principal} =
        platform_subject_fixture(%{
          provider: "lark-main",
          email: "match.target@example.com",
          mobile: "+14155550101"
        })

      assert {:ok, ^principal} =
               Principals.match_platform_subject_human(%{
                 provider: "slack-main",
                 external_id: "U_UNSEEN",
                 email: "Match.Target@example.com"
               })

      assert {:ok, ^principal} =
               Principals.match_platform_subject_human(%{
                 provider: "slack-main",
                 external_id: "U_UNSEEN",
                 mobile: "+1 415 555 0101"
               })
    end

    test "never creates anything on a miss" do
      assert {:error, :not_found} =
               Principals.match_platform_subject_human(%{
                 provider: "lark-main",
                 external_id: "ou_total_stranger",
                 email: "stranger@example.com"
               })

      assert {:error, :not_found} =
               Principals.resolve_platform_subject("lark-main", "ou_total_stranger")
    end

    test "reports a disabled principal instead of falling through" do
      %{principal: principal, identity: identity} =
        platform_subject_fixture(%{provider: "lark-main"})

      assert {:ok, _principal} = Principals.disable_principal(principal.uid)

      assert {:error, :principal_disabled} =
               Principals.match_platform_subject_human(%{
                 provider: "lark-main",
                 external_id: identity.external_id
               })
    end
  end

  describe "external identities" do
    test "external identity changeset requires the provider subject shape" do
      %{principal: principal} = human_fixture()

      assert {:error, changeset} =
               Principals.create_external_identity(%{
                 principal_uid: principal.uid,
                 external_id: "ou_bad",
                 metadata: %{}
               })

      assert %{provider: [_]} = errors_on(changeset)
    end

    test "external identity writes normalize principal_uid" do
      %{principal: principal} = human_fixture(%{uid: unique_uid("identity-owner")})

      assert {:ok, identity} =
               Principals.create_external_identity(%{
                 principal_uid: String.upcase(principal.uid),
                 provider: "lark-main",
                 external_id: unique_uid("actor"),
                 metadata: %{}
               })

      assert identity.principal_uid == principal.uid
    end

    test "upsert_external_identity/1 converges on the natural identity key" do
      first = human_fixture(%{uid: unique_uid("first-owner")})
      second = human_fixture(%{uid: unique_uid("second-owner")})
      external_id = unique_uid("actor")

      assert {:ok, inserted} =
               Principals.upsert_external_identity(%{
                 principal_uid: first.principal.uid,
                 provider: "lark-main",
                 external_id: external_id,
                 metadata: %{"source" => "first"}
               })

      assert {:ok, updated} =
               Principals.upsert_external_identity(%{
                 principal_uid: String.upcase(second.principal.uid),
                 provider: "lark-main",
                 external_id: external_id,
                 metadata: %{"source" => "second"}
               })

      assert updated.id == inserted.id
      assert updated.principal_uid == second.principal.uid
      assert updated.metadata == %{"source" => "second"}
    end

    test "create_external_identity/1 stores UUIDv7 ids for binding rows" do
      identity = external_identity_fixture()

      assert %ExternalIdentity{} = identity

      assert identity.id =~
               ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
    end
  end
end
