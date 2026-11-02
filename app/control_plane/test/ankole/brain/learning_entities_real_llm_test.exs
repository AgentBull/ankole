defmodule Ankole.Brain.LearningEntitiesRealLLMTest do
  @moduledoc "Real-provider acceptance for entity admission and source/subject separation."
  use Ankole.AIGatewayCase
  import Ankole.BrainFixtures
  import Ecto.Query

  alias Ankole.Brain.{ConversationsLearning, Objects, SchemaPacks, SourceLearning}
  alias Ankole.Brain.Schemas.{Claim, Page}

  @moduletag :real_llm
  @moduletag timeout: 300_000
  @model System.get_env("ANKOLE_REAL_LLM_MODEL", "z-ai/glm-5.3-flash")

  setup do
    {:ok, _} = SchemaPacks.install_packs([])

    {:ok, _} =
      ProviderConfigs.create_provider(%{
        provider_id: "entity-learning-real",
        provider_kind: "openrouter",
        credential_pool: %{
          "entries" => [
            %{"label" => "Test", "api_key" => System.fetch_env!("OPEN_ROUTER_API_KEY")}
          ]
        }
      })

    configure_brain_maintainer_profile!("light", "entity-learning-real", @model)

    {:ok, company} =
      page_fixture_result(
        %{
          slug: "companies/jizhi-tech",
          type: "company",
          title: "激智科技",
          body: "团队维护的公司档案。",
          meta: %{"aliases" => ["300566.SZ"]}
        },
        :system
      )

    %{company: company}
  end

  test "a research report files company assertions without consuming the report", %{
    company: company
  } do
    {:ok, legacy_unknown} =
      page_fixture_result(
        %{
          slug: "people/unknown",
          type: "person",
          title: "unknown"
        },
        :system
      )

    {:ok, report} =
      Ankole.Brain.create_object(
        %{
          slug: "documents/research-november",
          type: "document",
          subtype: "report",
          title: "11 月公司调研报告",
          body: """
          # 11 月公司调研报告
          我们长期跟进激智科技和 Cerebras 两家公司。
          激智科技（300566.SZ）计划在 2027 年新增两条光学膜产线，目前尚未投产。
          Cerebras 是一家芯片公司，其产品 CS3 使用晶圆级处理器。
          调研结论：继续跟踪两家公司的产能交付进展。
          访谈摘录（身份未核实）：unknown：我习惯每周五整理下周计划。
          助手：我建议买入激智科技；报告已准备并排队投递。
          研究员：没有采纳买入建议，目前也没有收到投递成功的回执。
          """
        },
        :system
      )

    assert {:ok, %{claims: count}} = SourceLearning.learn_page(report.id, report.revision)
    assert count >= 4
    claims = Repo.all(from c in Claim, where: c.source_node_id == ^report.id)
    assert Enum.any?(claims, &(&1.subject_page_id == company.id and &1.claim =~ "产线"))
    assert {:ok, cerebras} = Objects.resolve_reference("Cerebras")
    assert cerebras.type == "company"
    assert cerebras.slug =~ "companies/"
    assert Enum.any?(claims, &(&1.subject_page_id == cerebras.id))
    assert Enum.any?(claims, &(is_nil(&1.subject_page_id) and &1.claim =~ "周五"))
    refute Enum.any?(claims, &Regex.match?(~r/(已完成投递|投递成功了|报告已送达|用户接受了买入)/u, &1.claim))
    refute Enum.any?(claims, &(&1.subject_page_id == legacy_unknown.id))
    assert {:ok, after_report} = Objects.get_by_slug(report.id)
    assert {after_report.body, after_report.revision} == {report.body, report.revision}
    assert {:ok, after_company} = Objects.get_by_slug(company.id)
    assert {after_company.body, after_company.revision} == {company.body, company.revision}
    assert cerebras.body == ""
  end

  test "conversation memory reuses identities and retains decisions without task pages", %{
    company: company
  } do
    %{principal: alice} = human_fixture()

    {:ok, protocol} =
      page_fixture_result(
        %{
          slug: "documents/trading-review",
          type: "document",
          title: "交易复盘规程",
          meta: %{"aliases" => ["复盘协议"]}
        },
        :system
      )

    channel =
      Ankole.ExternalConversationsFixtures.create_external_conversation!(%{
        id: Ankole.Ecto.UUIDv7.autogenerate(),
        external_kind: :im_dm,
        reply_mode: :entry,
        title: "研究复盘",
        provider_conversation_id: "entity-real-demo",
        last_activity_at: DateTime.utc_now(:microsecond),
        first_seen_at: DateTime.utc_now(:microsecond),
        last_seen_at: DateTime.utc_now(:microsecond)
      })

    now = DateTime.utc_now(:microsecond)

    {:ok, _} =
      Repo.transact(fn ->
        Ankole.Conversations.External.observe_in_tx(
          channel.id,
          %{
            provider_message_id: "classification",
            provider_time: now,
            author: %{"principal_uid" => alice.uid, "display_name" => "Alice"},
            text: """
            我们继续长期跟进激智科技（300566.SZ），下季度重点确认新增产线的量产时间。
            复盘协议已从 v1.3 修订到 v1.4，同一份规程增加了逐条记录反证的要求，所有后续交易复盘都要执行。
            今天运行一次 job-1412 做 A 股现金扫描，执行日志显示任务结束；没有形成独立分析报告。
            行业研究 Skill.zip 是外部供应商发来的附件，尚未评估和安装，我决定下周评估它的适用性。
            我偏好先看研究摘要，再讨论细节，请在今后的研究沟通中遵循。
            """
          },
          now
        )
      end)

    assert {:ok, %{status: :complete, written: %{claims: count}}} =
             ConversationsLearning.process_conversation(channel.id)

    assert count >= 3
    {:ok, source_node_id} = Ankole.Brain.Scope.conversation(channel.id)
    claims = Repo.all(from c in Claim, where: c.source_node_id == ^source_node_id)
    assert Enum.any?(claims, &(&1.subject_page_id == company.id))
    assert Enum.any?(claims, &(&1.subject_page_id == protocol.id and &1.claim =~ "反证"))
    assert Enum.any?(claims, &(&1.kind == "preference" and &1.claim =~ "摘要"))
    refute Repo.exists?(from p in Page, where: like(p.slug, "%job-1412%"))
    refute Repo.exists?(from p in Page, where: p.type == "analysis")
    assert Repo.aggregate(from(p in Page, where: p.title == "激智科技"), :count) == 1
    assert {:ok, unchanged} = Objects.get_by_slug(protocol.id)
    assert unchanged.revision == protocol.revision
  end
end
