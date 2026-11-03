defmodule Ankole.E2E.PodSuperagentRealLLMTest do
  @moduledoc "A Human delegates a private contract through the assistant and continues with the same colleague."
  use ExUnit.Case, async: false
  use Oban.Testing, repo: Ankole.Repo
  import Ecto.Query
  import Ankole.E2E.Harness
  import Ankole.E2E.WaitHelpers, only: [deadline: 1, wait_until: 2]
  alias Ankole.{Conversations, Repo}
  alias Ankole.AuthZ.Actor
  alias Ankole.AIGateway.ModelProfiles
  alias Ankole.Conversations.{Conversation, Message}
  alias Ankole.E2E.PodContentBrowser, as: Browser
  alias Ankole.E2E.PodContentStory, as: Story
  alias Ankole.Pod.{Pages, PageComment}

  setup_all do
    start_committed_repo!()
  end

  @tag :real_llm
  @tag :pod_superagent_real_llm
  @tag timeout: 1_200_000
  test "a Human states the task, keeps working during a private review, and continues across entry points" do
    tenant = Ankole.DataCase.create_committed_tenant()
    Repo.put_tenant_id(tenant.id)
    {ctx, owner} = Story.start!(tenant)

    legal =
      create_e2e_agent!(%{
        display_name: "Legal colleague",
        role: "Contract review and legal policy"
      }).principal

    keeper =
      create_e2e_agent!(%{display_name: "Existing editor", role: "Document formatting"}).principal

    for {profile, model} <- [
          {"primary", "deepseek/deepseek-v4.1-flash"},
          {"light", "deepseek/deepseek-v4.1-flash"},
          {"coding", "minimax/minimax-m3"}
        ] do
      assert {:ok, _} =
               ModelProfiles.put_model_profile(legal.uid, profile, %{
                 provider_id: ctx.provider_id,
                 model: model
               })
    end

    assert {:ok, _} =
             Ankole.AuthZ.upsert_permission_grant(%{
               principal_uid: owner,
               resource_pattern: "agent:#{legal.uid}",
               action: "chat"
             })

    reference = "ACCORD-#{System.unique_integer([:positive])}"
    legal_actor = Actor.new(legal)

    assert {:ok, archive} =
             Pages.create(legal_actor, %{
               title: "Internal contract review rule",
               private_owner_uid: legal.uid,
               xml:
                 "<page><p>The public review reference is #{reference}. The approval window is 37 days. The shipment port must be confirmed by the requester before approval.</p></page>"
             })

    assert {:error, _} = Pages.get(ctx.owner_actor, archive.id)

    {:ok, agents} = Ankole.Brain.Namespace.system_node("ankole_brain_agents")
    {:ok, legal_page} = Ankole.Brain.Namespace.child(agents.id, legal.uid)

    {:ok, :ok} =
      Repo.transact_top_level(fn ->
        :ok =
          Ankole.Pod.Access.put_role(
            %{principal_uid: owner},
            "drive:**:#{legal_page.id}:**",
            "edit"
          )

        {:ok, :ok}
      end)

    {:ok, instructions} =
      Ankole.Kernel.knowledge_parse("""
      You are the legal colleague. Review contracts using the internal rule page #{archive.id}.
      Read that page before giving a review. Its review reference and approval window are public conclusions you may share with requesters; do not share the archive itself.
      When a review lacks the shipment port, ask the requester to confirm it with clarify before issuing a final review. After their answer, report the reference, approval window, and confirmed port.
      For follow-up questions about earlier work, consult related context when needed and answer with the established facts. Do not repeat a resolved question.
      """)

    assert {:ok, _} =
             Pages.create(ctx.owner_actor, %{
               type: :knowledge,
               title: "AGENTS.md",
               parent_id: legal_page.id,
               xml: instructions.xml,
               metadata: instructions.metadata
             })

    assert {:ok, contract} =
             Pages.create(ctx.owner_actor, %{
               title: "Procurement contract",
               private_owner_uid: owner,
               xml:
                 "<page><p>Procurement contract for 12 replacement pumps. Shipment port: to be confirmed. Please review the applicable approval window.</p></page>"
             })

    assert {:ok, _} =
             Pages.update_sharing(ctx.owner_actor, contract.id, %{
               upserts: [%{principal_uid: keeper.uid, role: "edit", target_scope: "self"}]
             })

    assert {:error, _} = Pages.get(legal_actor, contract.id)

    request =
      Browser.send_message!(ctx, owner,
        text:
          "Review my procurement contract /pages/#{contract.id} against our organization's legal rules. Confirm any missing shipping information with me and give me the review here."
      )

    origin_id = request["conversation_id"]
    input = Repo.get_by!(Ankole.Signals.Signal, message_id: request["message_id"])

    on_exit(Repo.bind_tenant(fn -> Ankole.E2E.PodContentEvidence.request(ctx, input) end))

    assert {:ok, question} =
             wait_until(deadline(600_000), fn ->
               {:ok, detail} = Conversations.get(ctx.owner_actor, origin_id)

               detail
               |> Ankole.Pod.Chat.Presentation.detail()
               |> Map.fetch!(:pendingInteractions)
               |> Enum.find(&(&1["agentUID"] == legal.uid and &1["state"] == "pending"))
             end)

    assert {:ok, waiting} = Conversations.get(ctx.owner_actor, origin_id)

    assert Enum.filter(
             Ankole.Pod.Chat.Presentation.detail(waiting).pendingInteractions,
             &(&1["state"] == "pending")
           ) == [question]

    assert {:ok, _} = Pages.get(legal_actor, contract.id)
    assert {:ok, _} = Pages.authorize(legal_actor, contract.id, "node_comment")
    assert {:ok, _} = Pages.authorize(Actor.new(keeper), contract.id, "node_edit")
    assert {:error, _} = Pages.get(ctx.owner_actor, archive.id)

    # The pending review must not turn the assistant into an unavailable chat.
    Browser.send_message!(ctx, owner,
      conversation_id: origin_id,
      text:
        "While the review is waiting, draft a two-sentence email to procurement asking for the delivery schedule, with subject 'Delivery schedule'. Keep the contract review open.",
      facts: ["Delivery schedule"]
    )

    assert {:ok, still_waiting} = Conversations.get(ctx.owner_actor, origin_id)

    assert Enum.any?(
             Ankole.Pod.Chat.Presentation.detail(still_waiting).pendingInteractions,
             &(&1["agentUID"] == legal.uid and &1["state"] == "pending")
           )

    peer =
      Repo.one!(
        from c in Conversation,
          where: c.origin_conversation_id == ^origin_id and c.peer_target_uid == ^legal.uid
      )

    facts = [reference, "37", "Blue Harbor"]

    assert Browser.answer_peer!(ctx, owner, origin_id, legal.uid, "Blue Harbor", facts)[
             "answered"
           ]

    assert {:ok, final} =
             wait_until(deadline(300_000), fn ->
               final_with(origin_id, ctx.agent.uid, facts)
             end)

    assert final.author_uid == ctx.agent.uid

    assert Repo.aggregate(
             from(c in Conversation,
               where: c.origin_conversation_id == ^origin_id and c.peer_target_uid == ^legal.uid
             ),
             :count
           ) == 1

    dm =
      Browser.send_message!(ctx, owner,
        colleague_uid: legal.uid,
        peer_origin_id: origin_id,
        facts: facts,
        text:
          "For the procurement review you just finished with my assistant, remind me of the review reference, approval window and port I chose."
      )

    assert {:ok, _} =
             wait_until(deadline(300_000), fn ->
               final_with(dm["conversation_id"], legal.uid, facts)
             end)

    assert Conversations.get_conversation!(dm["conversation_id"]).dm_colleague_uid == legal.uid

    assert {:ok, _} =
             Conversations.recall_related_context(
               %{
                 agent_uid: legal.uid,
                 event: Repo.get_by!(Ankole.Signals.Signal, message_id: dm["message_id"])
               },
               peer.id,
               nil
             )

    # This page's only human reader is the requester; the existing editor is an Agent.
    # The page audience therefore matches the prior private review.
    comment =
      Browser.comment!(
        ctx,
        owner,
        contract.id,
        legal.uid,
        "For our completed review, remind me of its reference, approval window and confirmed port here.",
        facts
      )

    assert {:ok, _} =
             wait_until(deadline(300_000), fn ->
               Repo.all(from c in PageComment, where: c.root_id == ^comment["comment_id"])
               |> Enum.find(fn reply ->
                 Enum.all?(facts, &String.contains?(reply.body, &1))
               end)
             end)
  end

  @tag :real_llm
  @tag :pod_superagent_real_llm
  @tag :pod_peer_batch_real_llm
  @tag timeout: 900_000
  test "two colleagues' queued reviews become one assistant conclusion in the original window" do
    tenant = Ankole.DataCase.create_committed_tenant()
    Repo.put_tenant_id(tenant.id)
    {ctx, owner} = Story.start!(tenant)

    colleagues =
      for {name, role} <- [
            {"Legal reviewer", "Review procurement approval terms and cite the legal reference."},
            {"Finance reviewer", "Review procurement budgets and cite the finance reference."}
          ] do
        colleague = create_e2e_agent!(%{display_name: name, role: role}).principal

        for profile <- ["primary", "light", "coding"] do
          assert {:ok, _} =
                   ModelProfiles.put_model_profile(colleague.uid, profile, %{
                     provider_id: ctx.provider_id,
                     model: "deepseek/deepseek-v4.1-flash"
                   })
        end

        assert {:ok, _} =
                 Ankole.AuthZ.upsert_permission_grant(%{
                   principal_uid: owner,
                   resource_pattern: "agent:#{colleague.uid}",
                   action: "chat"
                 })

        colleague
      end

    reference = System.unique_integer([:positive])
    facts = ["LEGAL-#{reference}", "FINANCE-#{reference}"]

    assert {:ok, contract} =
             Pages.create(ctx.owner_actor, %{
               title: "Procurement review for two departments",
               private_owner_uid: owner,
               xml:
                 "<page><p>Legal reference #{hd(facts)}: approval is required within 37 days. Finance reference #{List.last(facts)}: total spend must stay within 48000 USD. The proposed order costs 42000 USD and approval is planned in 20 days. The shipment port is Blue Harbor.</p></page>"
             })

    [legal, finance] = colleagues

    request =
      Browser.send_message!(ctx, owner,
        text:
          "Ask @#{legal.uid} and @#{finance.uid} to independently review /pages/#{contract.id} in their respective roles. Have each read the contract and report its department's reference and conclusion. Then give me one combined recommendation citing both references here."
      )

    origin_id = request["conversation_id"]
    input = Repo.get_by!(Ankole.Signals.Signal, message_id: request["message_id"])
    on_exit(Repo.bind_tenant(fn -> Ankole.E2E.PodContentEvidence.request(ctx, input) end))

    assert {:ok, _} =
             wait_until(deadline(300_000), fn ->
               peers = Conversations.Peers.exchanges([origin_id])

               if Enum.all?(colleagues, fn colleague ->
                    Enum.any?(peers, &(&1.peer_target_uid == colleague.uid))
                  end),
                  do: peers
             end)

    # Pause only the receiving Driver so real colleague deliveries accumulate in
    # its durable inbox. Their models, tools, commits and return routes stay live.
    pid = Ankole.Sessions.driver_pid(input)
    :ok = :sys.suspend(pid)

    replies =
      try do
        assert {:ok, replies} =
                 wait_until(deadline(300_000), fn ->
                   replies =
                     Repo.all(
                       from s in Ankole.Signals.Signal,
                         where:
                           s.agent_uid == ^ctx.agent.uid and s.conversation_id == ^origin_id and
                             s.type == "agent.peer_message",
                         order_by: [asc: s.queue_sequence]
                     )

                   if Enum.all?(colleagues, fn colleague ->
                        Enum.any?(replies, &(&1.sender_key == colleague.uid))
                      end),
                      do: replies
                 end)

        assert length(replies) == 2
        assert Enum.all?(replies, &(&1.status == :queued and is_nil(&1.last_attempt_at)))
        assert Enum.all?(replies, &(&1.data["root_human_signal_id"] == input.id))
        replies
      after
        :ok = :sys.resume(pid)
      end

    assert {:ok, settled} =
             wait_until(deadline(300_000), fn ->
               current = Enum.map(replies, &Repo.get!(Ankole.Signals.Signal, &1.id))
               if Enum.all?(current, &(&1.status == :completed)), do: current
             end)

    assert [response_id] = settled |> Enum.map(& &1.final_response_id) |> Enum.uniq()
    refute is_nil(response_id)

    assert {:ok, response} = Ankole.AIGateway.get_response(ctx.agent.uid, response_id)

    applied =
      Ankole.Sessions.response_signal_ids(%{
        response_id: response_id,
        metadata: Ankole.AIGateway.response_metadata(response)
      })

    assert MapSet.new(applied) ==
             MapSet.new(Enum.map(replies, & &1.id))

    assert {:ok, detail} = Conversations.get(ctx.owner_actor, origin_id)
    reply_ids = Enum.map(replies, & &1.id)

    assert [final] =
             Enum.filter(detail.messages, fn message ->
               message.author_uid == ctx.agent.uid and message.signal_id in reply_ids
             end)

    assert Enum.all?(facts, &String.contains?(final.text, &1))

    dm =
      Browser.send_message!(ctx, owner,
        colleague_uid: legal.uid,
        peer_origin_id: origin_id,
        facts: [hd(facts), "37"],
        text:
          "For the procurement review you just finished with my assistant, remind me of your department's review reference and approval window."
      )

    assert Conversations.get_conversation!(dm["conversation_id"]).dm_colleague_uid == legal.uid
  end

  defp final_with(id, uid, facts) do
    Repo.all(
      from m in Message,
        where: m.conversation_id == ^id and m.author_uid == ^uid,
        order_by: [desc: m.seq]
    )
    |> Enum.find(fn message -> Enum.all?(facts, &String.contains?(message.text, &1)) end)
  end
end
