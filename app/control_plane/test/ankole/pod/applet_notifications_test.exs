defmodule Ankole.Pod.AppletNotificationsTest do
  use Ankole.DataCase, async: false

  import Ankole.FilesFixtures, only: [publish_applet_fixture: 2]
  import Ankole.PrincipalsFixtures
  require Ash.Query

  alias Ankole.{AutomationJobs, Conversations, Signals}
  alias Ankole.Pod.{Applets, Pages}

  test "Applet notices reach a native room, are idempotent, and do not address an Agent" do
    owner = human_fixture().principal
    actor = actor_fixture(owner)
    recipient = human_fixture().principal
    outsider = human_fixture().principal
    agent = agent_fixture().principal
    Ankole.ConversationsFixtures.grant_chat(owner.uid, agent.uid)
    conversation_id = Ash.UUIDv7.generate()

    assert {:ok, _} =
             Ankole.ConversationsFixtures.create(owner.uid, %{
               conversation_id: conversation_id,
               message_id: Ash.UUIDv7.generate(),
               agent_uid: agent.uid,
               participant_uids: [recipient.uid],
               text: "Portfolio review"
             })

    {:ok, page} = Pages.create(actor, %{type: "applet", title: "Risk alerts"})

    share = %{
      inherit_permissions: false,
      grants: [
        %{principal_uid: recipient.uid, role: "view"},
        %{principal_uid: outsider.uid, role: "contribute"}
      ]
    }

    {:ok, _} = Ankole.Pod.PagesFixtures.set_sharing(owner.uid, page.id, share)

    publish_applet_fixture(%{actor: actor, page: page}, """
    export default {
      routes: {
        'POST /notify': ({body}) => AnkoleRuntime.notifications.post(body),
        'GET /notify': () => AnkoleRuntime.notifications.post({})
      },
      actions: {
        warn: {idempotent: true, handler: ctx => AnkoleRuntime.admin.notifications.post(ctx.signal.data)}
      }
    }
    """)

    prior_seq = Conversations.get_conversation!(conversation_id).last_notifiable_seq
    first = payload(conversation_id, "Review the portfolio limit.")

    assert {:ok, %{"status" => 403}} =
             call(actor_fixture(recipient), page.id, "POST", first)

    assert {:ok, %{"status" => 404}} =
             call(actor_fixture(outsider), page.id, "POST", first)

    assert {:ok, %{"body" => %{"error" => %{"code" => "read_only_route"}}}} =
             call(actor, page.id, "GET", first)

    receipt = Map.take(first, ~w(conversationId messageId))

    for _ <- 1..2 do
      assert {:ok, %{"status" => 200, "body" => ^receipt}} = call(actor, page.id, "POST", first)
    end

    assert Conversations.get_conversation!(conversation_id).last_notifiable_seq == prior_seq + 1

    assert {:ok, %{"status" => 409, "body" => %{"error" => %{"code" => "conversation_conflict"}}}} =
             call(actor, page.id, "POST", %{first | "text" => "Different notice"})

    {:ok, job} =
      AutomationJobs.create_applet_job(actor, page.id, "warn", %{authorization_kind: "service"})

    second = payload(conversation_id, "The daily check found a warning.")

    {:ok, %{automation_job_run: run}} =
      Repo.transact_top_level(fn ->
        AutomationJobs.enqueue_locked_in_tx(
          AutomationJobs.lock_job_in_tx(job.id),
          %{"data" => second},
          []
        )
      end)

    {:ok, attempt} = AutomationJobs.start_applet_attempt(run.id, 0)
    assert {:completed, %{"status" => 200}} = AutomationJobs.execute_applet_attempt(attempt)

    for %{"messageId" => id, "text" => text} <- [first, second] do
      assert %{author_uid: uid, text: ^text, rich_content: %{"applet_page_id" => applet_id}} =
               Ankole.Ash.read_one!(Ash.Query.filter(Conversations.Message, id == ^id))

      assert uid == owner.uid
      assert applet_id == page.id
      refute Ankole.Ash.exists?(Ash.Query.filter(Signals.Signal, message_id == ^id))
    end

    assert Conversations.get_conversation!(conversation_id).last_notifiable_seq == prior_seq + 2
  end

  defp payload(conversation_id, text),
    do: %{
      "conversationId" => conversation_id,
      "messageId" => Ash.UUIDv7.generate(),
      "text" => text
    }

  defp call(actor, page, method, body),
    do:
      Applets.call(actor, page, %{
        "method" => method,
        "path" => "/notify",
        "query" => %{},
        "body" => body
      })
end
