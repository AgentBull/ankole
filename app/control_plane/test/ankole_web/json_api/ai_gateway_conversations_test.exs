defmodule AnkoleWeb.JSONAPI.AIGatewayConversationsTest do
  @moduledoc "Checks the v2 AIGateway conversation routes: the list, one record, and its messages."
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AIGateway.Schemas.Conversation
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.Repo
  alias Ankole.Setup.Config, as: SetupConfig

  @media "application/vnd.api+json"

  setup do
    {:ok, true} = Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), true)
    :ok = SetupConfig.delete_bootstrap_activation_code()
    :ok
  end

  test "admin lists conversations with their display facts and pages the messages", %{
    conn: conn
  } do
    %{principal: agent} = agent_fixture()
    conn = console_conn(conn)
    job = conversation_fixture(agent.uid, Ankole.Sessions.Key.job("4000"))
    _empty = conversation_fixture(agent.uid, "custom:empty")
    messages = for _index <- 1..3, do: message_fixture(job)

    assert %{"data" => [listed]} =
             conn
             |> send_v2(
               :get,
               "/api/v2/ai-gateway/conversations?subject_uid=#{agent.uid}&min_messages=2"
             )
             |> json_response(200)

    assert listed["id"] == job.id

    assert %{
             "kind" => "job",
             "message_count" => 3,
             "display_name" => nil,
             "subject_uid" => subject_uid
           } = listed["attributes"]

    assert subject_uid == agent.uid

    assert %{"data" => %{"id" => id, "attributes" => %{"kind" => "job"}}} =
             conn
             |> send_v2(:get, "/api/v2/ai-gateway/conversations/#{job.id}")
             |> json_response(200)

    assert id == job.id

    path = "/api/v2/ai-gateway/conversations/#{job.id}/messages"
    first = conn |> send_v2(:get, "#{path}?page[limit]=2") |> json_response(200)
    next = URI.parse(first["links"]["next"])
    second = conn |> send_v2(:get, "#{next.path}?#{next.query}") |> json_response(200)

    assert Enum.map(first["data"] ++ second["data"], & &1["id"]) == Enum.map(messages, & &1.id)

    assert %{"type" => "ai_gateway_message", "attributes" => %{"type" => "message"}} =
             hd(first["data"])
  end

  test "an unknown conversation is not found, and a malformed id is rejected", %{conn: conn} do
    conn = console_conn(conn)

    assert %{"errors" => [%{"code" => "not_found"}]} =
             conn
             |> send_v2(:get, "/api/v2/ai-gateway/conversations/#{Ecto.UUID.generate()}")
             |> json_response(404)

    assert %{"data" => []} =
             conn
             |> send_v2(
               :get,
               "/api/v2/ai-gateway/conversations/#{Ecto.UUID.generate()}/messages"
             )
             |> json_response(200)

    assert %{"errors" => [_ | _]} =
             conn
             |> send_v2(:get, "/api/v2/ai-gateway/conversations/not-a-uuid/messages")
             |> json_response(400)
  end

  defp send_v2(conn, method, path) do
    conn
    |> recycle_api()
    |> put_req_header("accept", @media)
    |> put_req_header("content-type", @media)
    |> dispatch(@endpoint, method, path, nil)
  end

  defp conversation_fixture(subject_uid, key) do
    {:ok, conversation} =
      Ankole.Ash.create(Conversation, :open, %{
        subject_uid: subject_uid,
        conversation_key: key,
        metadata: %{}
      })

    conversation
  end

  defp message_fixture(conversation) do
    {:ok, message} =
      Repo.transact(fn ->
        Ankole.Ash.create(Message, :journal, %{
          subject_uid: conversation.subject_uid,
          conversation_id: conversation.id,
          content: [%{"type" => "text", "text" => "hi"}],
          metadata: %{}
        })
      end)

    message
  end
end
