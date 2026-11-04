defmodule Ankole.AgentWorkers.ReadToolBrokerTest do
  use Ankole.DataCase, async: true
  import Ankole.AIGatewayCase, only: [start_upstream_server: 1]
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

  test "the Job adapter transfers a complete page while the foreground owner keeps its byte window",
       %{
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
    assert byte_size(expected.output) <= 8_000
    assert hd(expected.details["results"])["next_offset"] < byte_size(text)
    assert actual["output"] == ""
    assert actual["web_cache"] == %{}
    assert [actual_page] = actual["details"]["results"]
    assert actual_page["url"] == @url
    assert actual_page["text"] == text
    assert actual_page["total_characters"] == 10_000
    assert actual_page["stored_characters"] == 10_000
    refute Map.has_key?(actual_page, "next_offset")
  end

  test "the private page index selects transport content without changing the validated model URL batch",
       %{
         turn: turn
       } do
    second = "https://example.com/second"
    at = System.system_time(:millisecond)

    cache = %{
      @url => %{at: at, page: %{"text" => "first"}},
      second => %{at: at, page: %{"text" => "second"}}
    }

    args = %{"urls" => [@url, second], "_workspace_page" => 1}
    request = request(args, web_cache_json: Ankole.JSON.encode!(cache))
    assert {:ok, actual} = ReadToolBroker.handle_read(turn, request, %{request_id: "read"})
    assert [%{"url" => ^second, "text" => "second"}] = actual["details"]["results"]

    declaration = Enum.find(Tools.Web.declarations(), &(&1["name"] == "web_fetch"))

    assert {:error, _} =
             Ankole.Sessions.ToolArguments.validate(declaration["parameters"], args)

    for index <- [-1, 2, "1"] do
      assert {:error, error} =
               ReadToolBroker.handle_read(
                 turn,
                 request(Map.put(args, "_workspace_page", index)),
                 %{request_id: "read"}
               )

      assert error["code"] == "invalid_read_tool_context"
    end
  end

  test "rendered fallback content uses the same bounded workspace transport", %{turn: turn} do
    rendered = %{
      "results" => [
        %{"text" => "rendered page", "metadata" => %{"source" => "rendered_fallback"}}
      ]
    }

    request = request(%{"urls" => [@url]}, rendered_body_json: Ankole.JSON.encode!(rendered))
    assert {:ok, actual} = ReadToolBroker.handle_read(turn, request, %{request_id: "read"})

    assert [%{"text" => "rendered page", "source" => "rendered_fallback"}] =
             actual["details"]["results"]

    assert actual["web_cache"] == %{}
  end

  test "the fenced rendered continuation retains the browser's true total and original tail", %{
    turn: turn
  } do
    text = String.duplicate("a", 2_000_000)
    tail = "TRUE-ORIGINAL-ENDING\n"

    rendered = %{
      "results" => [
        %{
          "text" => text,
          "total_characters" => 3_000_000,
          "stored_characters" => 2_000_000,
          "tail" => tail,
          "metadata" => %{"source" => "rendered_fallback"}
        }
      ]
    }

    assert {:ok, actual} =
             ReadToolBroker.handle_read(
               turn,
               request(%{"urls" => [@url], "_workspace_page" => 0},
                 rendered_body_json: Ankole.JSON.encode!(rendered)
               ),
               %{request_id: "read"}
             )

    assert [page] = actual["details"]["results"]
    assert page["text"] == text
    assert page["total_characters"] == 3_000_000
    assert page["stored_characters"] == 2_000_000
    assert page["tail"] == tail
    assert page["source"] == "rendered_fallback"
    assert actual["web_cache"] == %{}
  end

  test "a clean workspace-page repeat keeps its source and calls the real provider only once within 15 minutes",
       %{turn: turn} do
    parent = self()
    text = String.duplicate("Fetched article line.\n", 3_000)

    base_url =
      start_upstream_server(fn _request ->
        send(parent, :provider_fetch)
        {:json, 200, %{"data" => %{"url" => @url, "title" => "Article", "content" => text}}}
      end)

    assert {:ok, _} =
             Ankole.AIGateway.ProviderConfigs.create_provider(%{
               provider_id: "job-repeat-reader",
               provider_kind: "jina_reader",
               base_url: base_url,
               credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "test"}]}
             })

    assert {:ok, _} =
             Ankole.AIGateway.ModelProfiles.put_model_profile(turn.agent_uid, "web_fetch", %{
               "provider_id" => "job-repeat-reader",
               "model" => "default"
             })

    args = %{"urls" => [@url], "_workspace_page" => 0}
    assert {:ok, first} = ReadToolBroker.handle_read(turn, request(args), %{request_id: "first"})
    assert_receive :provider_fetch
    assert [page] = first["details"]["results"]
    assert page["repeat_fetch"] == false
    assert is_integer(page["cache_at"])
    assert is_nil(page["source"])
    cached_page = Map.put(page, "metadata", %{"source" => page["source"]})
    cache = %{@url => %{at: page["cache_at"], page: cached_page}}

    assert {:ok, repeated} =
             ReadToolBroker.handle_read(
               turn,
               request(args, web_cache_json: Ankole.JSON.encode!(cache)),
               %{request_id: "repeat"}
             )

    assert [%{"repeat_fetch" => true} = repeated_page] = repeated["details"]["results"]
    assert repeated_page["text"] == text
    assert repeated_page["source"] == page["source"]
    assert repeated_page["cache_at"] >= page["cache_at"]
    assert repeated["web_cache"] == %{}
    refute_receive :provider_fetch

    expired = %{@url => %{at: System.system_time(:millisecond) - 900_001, page: cached_page}}

    assert {:ok, refreshed} =
             ReadToolBroker.handle_read(
               turn,
               request(args, web_cache_json: Ankole.JSON.encode!(expired)),
               %{request_id: "expired"}
             )

    assert_receive :provider_fetch
    assert hd(refreshed["details"]["results"])["repeat_fetch"] == false
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
