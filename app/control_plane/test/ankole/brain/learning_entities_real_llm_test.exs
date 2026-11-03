defmodule Ankole.Brain.LearningEntitiesRealLLMTest do
  @moduledoc "Real-provider acceptance for entity admission and source/subject separation."
  use Ankole.AIGatewayCase
  import Ankole.BrainFixtures
  import Ecto.Query

  alias Ankole.Brain.{ConversationsLearning, Objects, SchemaPacks, SourceLearning, Sources}
  alias Ankole.Brain.Schemas.{Claim, Page}

  @moduletag :real_llm
  @moduletag timeout: 300_000
  @model System.get_env("ANKOLE_REAL_LLM_MODEL", "z-ai/glm-5.3-flash")
  @delivery_receipt """
  Deep Research 任务 **1535《A股 Level2 打板策略深度研究》**已完成。
  交付 PDF 与 Markdown 两个文件，文件已准备供交付。
  我也对交付版本执行了 `qpdf --check`，检查通过。
  任务成果为一份关于 A 股 Level2 打板策略的研究报告，A4 中文排版，公式已渲染。
  """

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

  test "a delivery receipt produces no memory or entity in either extraction path" do
    now = DateTime.utc_now(:microsecond)

    channel =
      Ankole.ExternalConversationsFixtures.create_external_conversation!(%{
        id: Ankole.Ecto.UUIDv7.autogenerate(),
        external_kind: :im_group,
        reply_mode: :entry,
        title: "研究交付",
        provider_conversation_id: "delivery-receipt",
        last_activity_at: now,
        first_seen_at: now,
        last_seen_at: now
      })

    {:ok, entry} =
      Repo.transact(fn ->
        Ankole.Conversations.External.observe_in_tx(
          channel.id,
          %{
            provider_message_id: "delivery",
            provider_time: now,
            author: %{"display_name" => "Deep Research Assistant"},
            text: @delivery_receipt
          },
          now
        )
      end)

    page_ids = Repo.all(from p in Page, select: p.id) |> MapSet.new()

    assert {:ok,
            %{
              status: :not_applicable,
              written: %{claims: 0, objects: 0, timelines: 0, links: 0, rejected: 0}
            }} = ConversationsLearning.process_conversation(channel.id)

    assert Sources.conversation_extraction_watermark(channel.id) == entry.message.seq
    assert MapSet.new(Repo.all(from p in Page, select: p.id)) == page_ids
    refute Repo.exists?(Claim)

    {:ok, source} =
      Ankole.Brain.create_object(
        %{
          slug: "documents/research-delivery-log",
          type: "document",
          title: "研究交付记录",
          body: @delivery_receipt
        },
        :system
      )

    assert {:ok, %{claims: 0, rejected: 0}} =
             SourceLearning.learn_page(source.id, source.revision)

    refute Repo.exists?(Claim)
    assert MapSet.new(Repo.all(from p in Page, select: p.id)) == MapSet.put(page_ids, source.id)
    assert {:ok, kept} = Objects.get_by_slug(source.id)
    assert {kept.body, kept.revision} == {source.body, source.revision}
  end

  test "mixed work notes retain conclusions and business outcomes without delivery trivia" do
    {:ok, report} =
      Ankole.Brain.create_object(
        %{
          slug: "documents/level2-research",
          type: "document",
          title: "Level2 研究与客户复盘",
          body: """
          助手：#{@delivery_receipt}
          助手的研究结论：集合竞价撤单不能视为真实成交，评估策略需要区分申报量和成交量。
          研究员陈扬：客户星河资本已签署本轮研究验收单，合同尾款为 30 万元。
          研究员陈扬：我承诺在 2026 年 11 月 15 日向客户提交策略风险复核意见。
          研究员陈扬：我长期偏好先看研究摘要，再讨论细节。
          复盘经验：qpdf --check 检查 PDF 文件结构，不能证明研究结论正确。
          """
        },
        :system
      )

    assert {:ok, %{claims: count}} = SourceLearning.learn_page(report.id, report.revision)
    assert count >= 5
    claims = Repo.all(from c in Claim, where: c.source_node_id == ^report.id)

    assert Enum.any?(claims, &(&1.claim =~ "撤单" and &1.claim =~ "成交"))
    assert Enum.any?(claims, &(&1.claim =~ "星河资本" and &1.claim =~ "验收"))
    assert Enum.any?(claims, &(&1.kind == "commitment" and &1.claim =~ "风险复核"))
    assert Enum.any?(claims, &(&1.kind == "preference" and &1.claim =~ "摘要"))
    assert Enum.any?(claims, &(&1.claim =~ "qpdf" and &1.claim =~ "结论"))

    refute Enum.any?(claims, fn claim ->
             Regex.match?(~r/1535|A4|公式.*渲染|qpdf.*(?:通过|成功)|文件.*(?:已生成|准备.*交付)/u, claim.claim)
           end)

    assert {:ok, kept} = Objects.get_by_slug(report.id)
    assert {kept.body, kept.revision} == {report.body, report.revision}
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
    refute Enum.any?(claims, &Regex.match?(~r/排队投递|投递成功的回执/u, &1.claim))
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
