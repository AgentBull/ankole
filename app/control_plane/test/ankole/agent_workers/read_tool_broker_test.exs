defmodule Ankole.AgentWorkers.ReadToolBrokerTest do
  use Ankole.DataCase, async: true
  alias Ankole.Sessions.JobTurnRef
  alias Ankole.Sessions.Tools
  alias Ankole.RuntimeFabric.V1.ReadToolRequest
  alias Ankole.Sessions.ReadToolBroker

  @url "https://example.com/article"
  setup do
    %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
    signal = Ankole.AIGateway.ResponseFixtures.signal_fixture(agent.uid, "job:1", "read-tool")

    %{
      turn: %JobTurnRef{
        agent_uid: agent.uid,
        session_id: signal.session_id,
        signal_id: signal.id,
        job_id: 1,
        attempt: 1
      }
    }
  end

  test "the Job adapter uses the main tool's cache, byte window and result contract", %{
    turn: turn
  } do
    text = String.duplicate("文章内容。", 2_000)
    page = %{"text" => text, "title" => "Article", "metadata" => %{"source" => "test"}}
    at = System.system_time(:millisecond)
    args = %{"urls" => [@url], "result_offset" => 0}

    assert {:ok, expected} =
             Tools.Web.execute(
               %{agent_uid: turn.agent_uid, web_cache: %{@url => %{at: at, page: page}}},
               %{"name" => "web_fetch"},
               args
             )

    request = request(args, web_cache_json: Ankole.JSON.encode!(%{@url => %{at: at, page: page}}))
    assert {:ok, actual} = ReadToolBroker.handle_read(turn, request, %{request_id: "read"})
    assert actual["output"] == expected.output
    assert actual["details"] == expected.details
    assert byte_size(actual["output"]) <= 8_000
    assert hd(actual["details"]["results"])["next_offset"] < byte_size(text)
    assert hd(actual["details"]["results"])["repeat_fetch"]
  end

  test "malformed cache and rendered contexts return RPC errors before provider I/O", %{
    turn: turn
  } do
    for context <- [
          [web_cache_json: ~s({"https://example.com/article":false})],
          [web_cache_json: ~s({"https://example.com/article":{"at":"bad","page":{}}})],
          [rendered_body_json: ~s({"results":[{"text":false}]})],
          [rendered_body_json: ~s({"results":{}})]
        ] do
      assert {:error, error} =
               ReadToolBroker.handle_read(turn, request(%{"urls" => [@url]}, context), %{
                 request_id: "read"
               })

      assert error["code"] == "invalid_read_tool_context"
    end
  end

  test "HTTPS admission applies to both the main tool and the Job adapter", %{turn: turn} do
    args = %{"urls" => ["http://example.com/article"]}

    assert {:error, "web_fetch requires HTTPS URLs"} =
             Tools.Web.execute(%{}, %{"name" => "web_fetch"}, args)

    assert {:error, error} =
             ReadToolBroker.handle_read(turn, request(args), %{request_id: "read"})

    assert error["message"] == "web_fetch requires HTTPS URLs"
  end

  defp request(args, context \\ []) do
    struct!(
      ReadToolRequest,
      Keyword.merge([name: "web_fetch", arguments_json: Ankole.JSON.encode!(args)], context)
    )
  end
end
