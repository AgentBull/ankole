defmodule Ankole.AIAgent.TokenQuotaTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AIAgent.TokenQuota
  alias Ankole.AIGateway.Schemas.UsageRecord
  alias Ankole.Principals.Agent

  @day 86_400

  setup do
    %{principal: agent} = agent_fixture()
    %{agent_uid: agent.uid}
  end

  describe "configuration" do
    test "a written quota keeps the model profiles of the same Agent", %{agent_uid: agent_uid} do
      assert {:ok, _profile} =
               Ankole.AIAgent.ModelProfiles.put_provider_hosted_capabilities(agent_uid, %{
                 "web_search" => false
               })

      assert {:ok, quota} = put_quota(agent_uid, 7, "2026-09-09T00:00:00Z", 1_000_000)

      assert quota == %{
               "period_days" => 7,
               "period_start_at" => "2026-09-09T00:00:00Z",
               "limit_tokens" => 1_000_000
             }

      assert %Agent{options: options} = Repo.get!(Agent, agent_uid)
      assert get_in(options, ["ai_agent", "provider_hosted", "web_search"]) == false
      assert get_in(options, ["ai_agent", "token_quota", "limit_tokens"]) == 1_000_000
    end

    test "an invalid period, start time, or limit is rejected", %{agent_uid: agent_uid} do
      assert {:error, :invalid_period_days} = put_quota(agent_uid, 0, "2026-09-09T00:00:00Z", 10)
      assert {:error, :invalid_limit_tokens} = put_quota(agent_uid, 7, "2026-09-09T00:00:00Z", 0)

      assert {:error, :invalid_period_start_at} = put_quota(agent_uid, 7, "not-an-instant", 10)

      assert {:error, :invalid_period_days} =
               TokenQuota.put(agent_uid, %{
                 "period_start_at" => "2026-09-09T00:00:00Z",
                 "limit_tokens" => 10
               })
    end

    test "an unknown Agent cannot be written", %{agent_uid: _agent_uid} do
      assert {:error, :agent_not_found} = put_quota("no-such-agent", 7, "2026-09-09T00:00:00Z", 1)
    end

    test "a deleted quota leaves the Agent without a limit", %{agent_uid: agent_uid} do
      assert {:ok, _quota} = put_quota(agent_uid, 7, "2026-09-09T00:00:00Z", 1)
      assert {:ok, nil} = TokenQuota.delete(agent_uid)
      assert {:ok, %{token_quota: nil, usage: nil}} = TokenQuota.status(agent_uid)
      assert :ok = TokenQuota.ensure_available(agent_uid)
    end

    test "an Agent without a quota cannot be reset", %{agent_uid: agent_uid} do
      assert {:error, :token_quota_not_configured} = TokenQuota.reset(agent_uid)
    end
  end

  describe "window" do
    test "the window tiles the timeline from the period start", %{agent_uid: agent_uid} do
      start_at = DateTime.utc_now() |> DateTime.add(-10 * @day, :second)
      assert {:ok, _quota} = put_quota(agent_uid, 7, DateTime.to_iso8601(start_at), 1_000)

      assert {:ok, %{usage: usage}} = TokenQuota.status(agent_uid)
      assert DateTime.compare(usage.window_started_at, DateTime.add(start_at, 7 * @day)) == :eq
      assert DateTime.compare(usage.window_ends_at, DateTime.add(start_at, 14 * @day)) == :eq
      assert usage.used_tokens == 0
      refute usage.exceeded
    end

    test "a period start in the future counts the window before it", %{agent_uid: agent_uid} do
      start_at = DateTime.utc_now() |> DateTime.add(@day, :second)
      assert {:ok, _quota} = put_quota(agent_uid, 7, DateTime.to_iso8601(start_at), 1_000)

      assert {:ok, %{usage: usage}} = TokenQuota.status(agent_uid)
      assert DateTime.compare(usage.window_started_at, DateTime.add(start_at, -7 * @day)) == :eq
      assert DateTime.compare(usage.window_ends_at, start_at) == :eq
    end

    test "only the rows of the current window count", %{agent_uid: agent_uid} do
      start_at = DateTime.utc_now() |> DateTime.add(-3 * @day, :second)
      assert {:ok, _quota} = put_quota(agent_uid, 2, DateTime.to_iso8601(start_at), 1_000)

      assert {:ok, %{usage: %{window_started_at: window_started_at}}} =
               TokenQuota.status(agent_uid)

      record_usage(agent_uid, 400, 100, DateTime.add(window_started_at, -1, :second))
      record_usage(agent_uid, 300, 200, DateTime.add(window_started_at, 1, :second))

      assert {:ok, %{usage: usage}} = TokenQuota.status(agent_uid)
      assert usage.used_tokens == 500
      refute usage.exceeded
    end

    test "usage at or above the limit rejects the next request", %{agent_uid: agent_uid} do
      start_at = DateTime.utc_now() |> DateTime.add(-60, :second)
      assert {:ok, _quota} = put_quota(agent_uid, 7, DateTime.to_iso8601(start_at), 500)

      record_usage(agent_uid, 300, 200, DateTime.utc_now())

      assert {:error, {:agent_token_quota_exceeded, window}} =
               TokenQuota.ensure_available(agent_uid)

      assert window.used_tokens == 500
      assert window.limit_tokens == 500
      assert window.exceeded
    end
  end

  describe "reset" do
    test "a reset starts an empty window and keeps the ledger", %{agent_uid: agent_uid} do
      start_at = DateTime.utc_now() |> DateTime.add(-60, :second)
      assert {:ok, _quota} = put_quota(agent_uid, 7, DateTime.to_iso8601(start_at), 500)

      record_usage(agent_uid, 300, 200, DateTime.utc_now())

      assert {:error, {:agent_token_quota_exceeded, _window}} =
               TokenQuota.ensure_available(agent_uid)

      assert {:ok, quota} = TokenQuota.reset(agent_uid)
      assert quota["period_days"] == 7
      assert quota["limit_tokens"] == 500

      assert :ok = TokenQuota.ensure_available(agent_uid)
      assert {:ok, %{usage: usage}} = TokenQuota.status(agent_uid)
      assert usage.used_tokens == 0
      assert Repo.aggregate(UsageRecord, :count) == 1
    end
  end

  defp put_quota(agent_uid, period_days, period_start_at, limit_tokens) do
    TokenQuota.put(agent_uid, %{
      "period_days" => period_days,
      "period_start_at" => period_start_at,
      "limit_tokens" => limit_tokens
    })
  end

  defp record_usage(agent_uid, input_tokens, output_tokens, %DateTime{} = inserted_at) do
    Repo.insert!(%UsageRecord{
      subject_uid: agent_uid,
      origin: "agent",
      model: "test-provider/test-model",
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      inserted_at: inserted_at
    })
  end
end
