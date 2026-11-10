defmodule AnkoleWeb.JSONAPI.AIGatewayUsageTest do
  @moduledoc "Checks the Console usage summary: totals by Agent, Human, and origin with reported coverage."
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AIGateway.Schemas.UsageRecord
  alias Ankole.Setup.Config, as: SetupConfig

  @media "application/vnd.api+json"

  setup do
    {:ok, true} = Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), true)
    :ok = SetupConfig.delete_bootstrap_activation_code()
    :ok
  end

  test "an administrator reads usage totals with how many rounds reported their tokens", %{
    conn: conn
  } do
    %{principal: agent} = agent_fixture()
    %{principal: human} = human_fixture()

    record!(agent.uid, :agent, human.uid, 100, 20)
    record!(agent.uid, :agent, human.uid, nil, nil)
    record!(agent.uid, :compaction, nil, 50, 5)
    # A Human's own OIDC call belongs to that Human and is no Agent's usage.
    record!(human.uid, :oidc_human, human.uid, 0, 0)

    assert %{
             "total" => total,
             "by_agent" => [by_agent],
             "by_human" => by_human,
             "by_origin" => by_origin,
             "window_started_at" => window_started_at
           } =
             conn
             |> console_conn()
             |> recycle_api()
             |> put_req_header("accept", @media)
             |> put_req_header("content-type", @media)
             |> get("/api/v2/ai-gateway/usage?days=30")
             |> json_response(200)

    assert {:ok, _started_at, 0} = DateTime.from_iso8601(window_started_at)

    assert %{
             "rounds" => 4,
             "reported_rounds" => 3,
             "input_tokens" => 150,
             "output_tokens" => 25,
             "cached_input_tokens" => nil,
             "cache_creation_input_tokens" => nil
           } = total

    assert by_agent["key"] == agent.uid
    assert by_agent["name"] == agent.display_name

    assert [
             %{"key" => human_uid, "rounds" => 3, "reported_rounds" => 2, "input_tokens" => 100},
             %{"key" => nil, "rounds" => 1}
           ] = by_human

    assert human_uid == human.uid
    assert hd(by_human)["name"] == human.display_name

    assert [
             %{"key" => "agent", "rounds" => 2},
             %{"key" => "compaction", "rounds" => 1, "output_tokens" => 5},
             %{"key" => "oidc_human", "rounds" => 1}
           ] = by_origin
  end

  test "a deleted Agent keeps its usage in the Agent breakdown", %{conn: conn} do
    %{principal: agent} = agent_fixture()
    record!(agent.uid, :agent, nil, 100, 20)

    # Deleting first disables the Agent and then removes it.
    assert {:ok, _disabled} = Ankole.Principals.delete_agent(agent.uid)
    assert {:ok, _deleted} = Ankole.Principals.delete_agent(agent.uid)

    assert %{"total" => %{"rounds" => 1}, "by_agent" => [row]} =
             conn
             |> console_conn()
             |> recycle_api()
             |> put_req_header("accept", @media)
             |> put_req_header("content-type", @media)
             |> get("/api/v2/ai-gateway/usage")
             |> json_response(200)

    assert %{"rounds" => 1, "input_tokens" => 100, "name" => nil} = row
    assert row["key"] == agent.uid
  end

  test "a signed-in Human without a Console grant is refused", %{conn: conn} do
    %{principal: member} = human_fixture()

    assert %{"error" => %{"code" => "forbidden"}} =
             conn
             |> Plug.Test.init_test_session(%{})
             |> AnkoleWeb.Session.put_tenant_session(%{
               principal_uid: member.uid,
               provider_id: "lark-main",
               external_id: "external-member"
             })
             |> with_console_csrf()
             |> get(~p"/api/v2/browser/session")
             |> recycle_api()
             |> put_req_header("accept", @media)
             |> put_req_header("content-type", @media)
             |> get("/api/v2/ai-gateway/usage")
             |> json_response(403)
  end

  defp record!(agent_uid, origin, human_uid, input, output) do
    assert {:ok, _record} =
             Ankole.Ash.create(UsageRecord, :record_round, %{
               subject_uid: agent_uid,
               origin: origin,
               model: "usage-console/gpt-5.5",
               human_uid: human_uid,
               input_tokens: input,
               output_tokens: output
             })
  end
end
