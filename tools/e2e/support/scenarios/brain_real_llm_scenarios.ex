defmodule Ankole.E2E.Scenarios.BrainRealLLM do
  @moduledoc """
  Brain acceptance scenarios over the real product path.

  Fake Feishu replaces only the human client. User-facing scenarios travel
  through the real Lark adapter, SignalsGateway, ActorRuntime, Docker worker,
  OpenRouter model, Brain RuntimeFabric RPC, PostgreSQL commit, and provider
  outbox. A scenario may seed an exact prerequisite through the same Brain
  facade when its target is a downstream lifecycle such as source withdrawal.
  """

  import Ecto.Query
  import ExUnit.Assertions

  import Ankole.E2E.Harness

  import Ankole.E2E.WaitHelpers,
    only: [
      ai_messages_for_actor_event: 1,
      deadline: 1,
      wait_for_completed_final_reply: 3,
      wait_until: 2
    ]

  alias Ankole.AIAgent.Library.Schemas.AgentSkillOverlay
  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AppConfigure
  alias Ankole.Brain
  alias Ankole.Brain.Config, as: BrainConfig
  alias Ankole.Brain.Jobs.WithdrawSource
  alias Ankole.Brain.Knowledge
  alias Ankole.Brain.Schemas.AuditLog
  alias Ankole.Brain.Schemas.Cursor
  alias Ankole.Brain.Schemas.Entry, as: BrainEntry
  alias Ankole.Brain.Schemas.EntryBlock
  alias Ankole.Brain.Scope
  alias Ankole.E2E.FakeFeishu
  alias Ankole.Plugins.LarkAdapter.IMGroups
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.AdapterContext
  alias Ankole.SignalsGateway.OutboxEntry
  alias Oban.Job

  @base_time ~U[2026-07-12 04:00:00.000000Z]
  @stale_review_offset_ms 100 * 24 * 60 * 60 * 1_000
  @language_model "openai/gpt-5.6-luna"
  @embedding_model "perplexity/pplx-embed-v1-0.6b"

  @doc "Adds the model profiles and scoped policy required by Brain dreaming."
  def prepare_brain_real_llm!(%{agent: agent, provider_id: provider_id} = ctx) do
    for {profile, model} <- [
          {"primary", @language_model},
          {"light", @language_model},
          {"heavy", @language_model},
          {"embedding", @embedding_model}
        ] do
      assert {:ok, _profile} =
               ModelProfiles.put_model_profile(agent.uid, profile, %{
                 provider_id: provider_id,
                 model: model,
                 provider_options:
                   if(model == @language_model,
                     do: %{"reasoningEffort" => "low"},
                     else: %{}
                   )
               })
    end

    assert :ok = BrainConfig.ensure_registered()

    assert {:ok, global_current} = BrainConfig.dreaming()

    global_config =
      global_current
      |> Map.put("enabled", true)
      |> Map.put("model_agent_uid", agent.uid)

    assert {:ok, _stored} =
             AppConfigure.put_global(BrainConfig.dreaming_definition(), global_config)

    assert {:ok, current} = BrainConfig.dreaming(agent.uid)

    configured =
      current
      |> Map.put("enabled", true)
      |> Map.put("model_agent_uid", agent.uid)
      |> Map.put("material_limit", 240)
      |> Map.put("token_limit", 0)
      |> Map.put("mutation_limit", 0)

    assert {:ok, _stored} =
             AppConfigure.put_for_agent(
               agent.uid,
               BrainConfig.dreaming_definition(),
               configured
             )

    ctx
  end

  @doc "Preference correction replaces the current fact and search no longer returns the stale value."
  def run_preference_evolution(ctx) do
    created =
      addressed_turn!(ctx,
        event_id: "evt_brain_preference_create",
        message_id: "om_brain_preference_create",
        chat_id: "oc_brain_preference_dm",
        chat_type: "p2p",
        offset_ms: 1_000,
        marker: "BRAIN_PREFERENCE_CREATED",
        text: """
        我的饮食偏好是烤肉，当前事实标识为 MEAT_PREF_OLD。请用 memory_update 创建且只创建一个名为「饮食偏好」的 preference 词条，把这个当前偏好写清楚。不要创建第二个同义词条。工具成功后回复 BRAIN_PREFERENCE_CREATED。
        """
      )

    assert_successful_operation!(created.messages, "create_entry")
    original = brain_entry_by_name!(ctx.agent.uid, "饮食偏好")
    assert original.store_key == "dm:ou_alice"
    assert entry_text(original) =~ "MEAT_PREF_OLD"

    corrected =
      addressed_turn!(ctx,
        event_id: "evt_brain_preference_correct",
        message_id: "om_brain_preference_correct",
        chat_id: "oc_brain_preference_dm",
        chat_type: "p2p",
        offset_ms: 2_000,
        marker: "BRAIN_PREFERENCE_CORRECTED",
        text: """
        纠正之前的偏好：我现在改吃素，当前事实标识为 PLANT_PREF_CURRENT。先用 memory_open 打开「饮食偏好」，再用 memory_update 原位覆盖旧事实；当前投影里不得保留 MEAT_PREF_OLD，也不要新建词条。工具成功后回复 BRAIN_PREFERENCE_CORRECTED。
        """
      )

    assert_tool_succeeded!(corrected.messages, "memory_open")
    assert_successful_memory_update!(corrected.messages)
    refute_successful_operation!(corrected.messages, "create_entry")

    current = brain_entry_by_name!(ctx.agent.uid, "饮食偏好")
    assert current.lock_version > original.lock_version
    assert entry_text(current) =~ "PLANT_PREF_CURRENT"
    refute entry_text(current) =~ "MEAT_PREF_OLD"
    assert brain_entry_count(ctx.agent.uid, "饮食偏好") == 1

    recalled =
      addressed_turn!(ctx,
        event_id: "evt_brain_preference_search",
        message_id: "om_brain_preference_search",
        chat_id: "oc_brain_preference_dm",
        chat_type: "p2p",
        offset_ms: 3_000,
        marker: "BRAIN_PREFERENCE_SEARCHED",
        text: """
        请用 memory_search 在 knowledge 层检索「饮食偏好」，只按工具返回的当前投影回答，然后回复 BRAIN_PREFERENCE_SEARCHED。
        """
      )

    search_output = successful_tool_output!(recalled.messages, "memory_search")
    assert_tool_arguments!(recalled.messages, "memory_search", %{"layer" => "knowledge"})
    assert search_output =~ "PLANT_PREF_CURRENT"
    refute search_output =~ "MEAT_PREF_OLD"

    %{entry: current, turns: [created, corrected, recalled]}
  end

  @doc "A rumor is recorded as unverified, then replaced by the cited official announcement."
  def run_rumor_to_announcement(ctx) do
    rumor_source =
      record_source!(ctx,
        event_id: "evt_brain_rumor_source",
        message_id: "om_brain_rumor_source",
        chat_id: "oc_brain_rumor",
        offset_ms: 10_000,
        text: "传闻 Project Cobalt 将在 8 月 1 日发布，尚未得到官方确认。"
      )

    rumor_write =
      addressed_turn!(ctx,
        event_id: "evt_brain_rumor_write",
        message_id: "om_brain_rumor_write",
        chat_id: "oc_brain_rumor",
        chat_type: "group",
        offset_ms: 11_000,
        marker: "BRAIN_RUMOR_RECORDED",
        text: """
        请先用 memory_browse 回读本频道上一条 Project Cobalt 传闻并取得它的 document_id。然后用 memory_update 创建「Project Cobalt 发布状态」词条，并追加一个正文块：明确写成未证实传闻，逐字带上 src:<document_id> 出处。工具成功后回复 BRAIN_RUMOR_RECORDED。
        """
      )

    assert_tool_succeeded!(rumor_write.messages, "memory_browse")
    assert_successful_operation!(rumor_write.messages, "create_entry")
    assert_successful_operation!(rumor_write.messages, "append_block")

    rumor_entry = brain_entry_by_name!(ctx.agent.uid, "Project Cobalt 发布状态")
    rumor_text = entry_text(rumor_entry)
    assert rumor_text =~ "src:#{rumor_source.document_id}"
    assert rumor_text =~ "未证实"

    announcement_source =
      record_source!(ctx,
        event_id: "evt_brain_announcement_source",
        message_id: "om_brain_announcement_source",
        chat_id: "oc_brain_rumor",
        offset_ms: 12_000,
        text: "Project Cobalt 官方公告：发布日期确认为 8 月 15 日。"
      )

    announcement_write =
      addressed_turn!(ctx,
        event_id: "evt_brain_announcement_write",
        message_id: "om_brain_announcement_write",
        chat_id: "oc_brain_rumor",
        chat_type: "group",
        offset_ms: 13_000,
        marker: "BRAIN_ANNOUNCEMENT_RECORDED",
        text: """
        官方公告已经替代旧传闻。请先用 memory_browse 取得上一条官方公告的 document_id，再用 memory_open 打开「Project Cobalt 发布状态」，并用 memory_update 原位改写原正文块。最终当前投影只保留「官方确认 8 月 15 日」和新的 src:<document_id>，不要保留旧传闻出处。工具成功后回复 BRAIN_ANNOUNCEMENT_RECORDED。
        """
      )

    assert_tool_succeeded!(announcement_write.messages, "memory_browse")
    assert_tool_succeeded!(announcement_write.messages, "memory_open")
    assert_successful_operation!(announcement_write.messages, "edit_block")

    current = brain_entry_by_name!(ctx.agent.uid, "Project Cobalt 发布状态")
    current_text = entry_text(current)
    assert current_text =~ "8 月 15 日"
    assert current_text =~ "src:#{announcement_source.document_id}"
    refute current_text =~ rumor_source.document_id
    assert length(entry_blocks(current.id)) == 1

    %{entry: current, turns: [rumor_write, announcement_write]}
  end

  @doc "DM knowledge is structurally hidden from groups while public knowledge remains readable in DM."
  def run_dm_isolation(ctx) do
    private =
      addressed_turn!(ctx,
        event_id: "evt_brain_dm_private",
        message_id: "om_brain_dm_private",
        chat_id: "oc_brain_private_dm",
        chat_type: "p2p",
        offset_ms: 20_000,
        marker: "BRAIN_DM_PRIVATE_STORED",
        text: """
        这是私聊事实：Project Nightjar 的口令是 NIGHTJAR_PRIVATE_731。请用 memory_update 创建名为「Project Nightjar」的 project_secret 词条，写进当前私聊库。工具成功后回复 BRAIN_DM_PRIVATE_STORED。
        """
      )

    assert_successful_operation!(private.messages, "create_entry")
    private_entry = brain_entry_by_name!(ctx.agent.uid, "Project Nightjar")
    assert private_entry.store_key == "dm:ou_alice"

    group_search =
      addressed_turn!(ctx,
        event_id: "evt_brain_group_private_search",
        message_id: "om_brain_group_private_search",
        chat_id: "oc_brain_public_group",
        chat_type: "group",
        offset_ms: 21_000,
        marker: "BRAIN_GROUP_PRIVATE_SEARCH_DONE",
        text: """
        请用 memory_search 在 knowledge 层检索「Project Nightjar」，channel_scope=all_channels。只按工具结果回答，不要猜测，然后回复 BRAIN_GROUP_PRIVATE_SEARCH_DONE。
        """
      )

    private_search_output = successful_tool_output!(group_search.messages, "memory_search")

    assert_tool_arguments!(group_search.messages, "memory_search", %{
      "layer" => "knowledge",
      "channel_scope" => "all_channels"
    })

    refute private_search_output =~ "NIGHTJAR_PRIVATE_731"

    public =
      addressed_turn!(ctx,
        event_id: "evt_brain_public_create",
        message_id: "om_brain_public_create",
        chat_id: "oc_brain_public_group",
        chat_type: "group",
        offset_ms: 22_000,
        marker: "BRAIN_PUBLIC_STORED",
        text: """
        这是公共团队事实：Public Operations Policy 的当前标识是 PUBLIC_POLICY_GREEN。请用 memory_update 创建且只创建一个名称逐字等于「Public Operations Policy」的 policy 词条。工具成功后回复 BRAIN_PUBLIC_STORED。
        """
      )

    assert_successful_operation!(public.messages, "create_entry")

    assert_tool_arguments!(public.messages, "memory_update", %{
      "operation" => "create_entry",
      "name" => "Public Operations Policy"
    })

    public_entry = brain_entry_by_name!(ctx.agent.uid, "Public Operations Policy")
    assert public_entry.store_key == "public"

    dm_search =
      addressed_turn!(ctx,
        event_id: "evt_brain_dm_public_search",
        message_id: "om_brain_dm_public_search",
        chat_id: "oc_brain_private_dm",
        chat_type: "p2p",
        offset_ms: 23_000,
        marker: "BRAIN_DM_PUBLIC_SEARCH_DONE",
        text: """
        请用 memory_search 在 knowledge 层检索「Public Operations Policy」，只按工具结果回答，然后回复 BRAIN_DM_PUBLIC_SEARCH_DONE。
        """
      )

    public_search_output = successful_tool_output!(dm_search.messages, "memory_search")
    assert_tool_arguments!(dm_search.messages, "memory_search", %{"layer" => "knowledge"})
    assert public_search_output =~ "PUBLIC_POLICY_GREEN"

    refute Repo.exists?(
             from(entry in BrainEntry,
               where: entry.owner_uid == ^ctx.agent.uid,
               where: entry.store_key == "public",
               where: entry.name == "Project Nightjar"
             )
           )

    %{private: private_entry, public: public_entry}
  end

  @doc "Stage B consolidates repeated material once and advances its principal cursor."
  def run_dreaming_idempotence(ctx) do
    Enum.each(
      [
        {"evt_brain_dream_source_1", "om_brain_dream_source_1", 30_000,
         "Project Dawn 的负责人是 Ada，知识标识 DAWN_OWNER_ADA。"},
        {"evt_brain_dream_source_2", "om_brain_dream_source_2", 31_000,
         "再次确认 Project Dawn 由 Ada 负责，里程碑在 9 月。"},
        {"evt_brain_dream_source_3", "om_brain_dream_source_3", 32_000,
         "Project Dawn 的 9 月里程碑需要 Ada 最终签字。"}
      ],
      fn {event_id, message_id, offset_ms, text} ->
        record_source!(ctx,
          event_id: event_id,
          message_id: message_id,
          chat_id: "oc_brain_dreaming",
          offset_ms: offset_ms,
          text: text
        )
      end
    )

    _visibility_anchor =
      addressed_turn!(ctx,
        event_id: "evt_brain_dream_visibility",
        message_id: "om_brain_dream_visibility",
        chat_id: "oc_brain_dreaming",
        chat_type: "group",
        offset_ms: 33_000,
        marker: "BRAIN_DREAM_CHANNEL_READY",
        text: """
        请只回复 BRAIN_DREAM_CHANNEL_READY，不要调用任何工具。
        """
      )

    ensure_lark_group_joined!(ctx, "oc_brain_dreaming")

    assert Enum.any?(
             SignalsGateway.visible_channels(ctx.agent.uid),
             &(&1.id == "lark:oc_brain_dreaming")
           )

    assert {:ok, %{status: :completed} = first_run} = Brain.run_dreaming(ctx.agent.uid)

    dreaming_blocks =
      EntryBlock
      |> where([block], block.owner_uid == ^ctx.agent.uid)
      |> where([block], block.author_kind == :dreaming)
      |> Repo.all()

    assert dreaming_blocks != []

    assert Enum.any?(
             dreaming_blocks,
             &(String.contains?(&1.body, "DAWN_OWNER_ADA") or
                 String.contains?(&1.body, "Project Dawn"))
           )

    block_count = length(dreaming_blocks)
    audit_count = dreaming_audit_count(ctx.agent.uid)

    assert {:ok, %{status: :no_new_material} = second_run} = Brain.run_dreaming(ctx.agent.uid)
    assert dreaming_block_count(ctx.agent.uid) == block_count
    assert dreaming_audit_count(ctx.agent.uid) == audit_count
    assert %Cursor{} = Repo.get_by(Cursor, scope_kind: :principal, scope_key: ctx.agent.uid)

    recalled =
      addressed_turn!(ctx,
        event_id: "evt_brain_dream_search",
        message_id: "om_brain_dream_search",
        chat_id: "oc_brain_dreaming",
        chat_type: "group",
        offset_ms: 34_000,
        marker: "BRAIN_DREAM_SEARCHED",
        text: """
        请先用 memory_search 在 knowledge 层检索 Project Dawn，并明确设置 author_kind=dreaming；再用 memory_open 打开命中的词条，只按工具结果回答，然后回复 BRAIN_DREAM_SEARCHED。
        """
      )

    assert successful_tool_output!(recalled.messages, "memory_search") =~ "Dawn"

    assert_tool_arguments!(recalled.messages, "memory_search", %{
      "layer" => "knowledge",
      "author_kind" => "dreaming"
    })

    assert_tool_succeeded!(recalled.messages, "memory_open")

    %{first_run: first_run, second_run: second_run, blocks: dreaming_blocks}
  end

  @doc "A human-initiated review starts read-only and applies the later oral decision through Brain."
  def run_human_review(ctx) do
    seeded =
      addressed_turn!(ctx,
        event_id: "evt_brain_review_seed",
        message_id: "om_brain_review_seed",
        chat_id: "oc_brain_review",
        chat_type: "group",
        offset_ms: 40_000,
        marker: "BRAIN_REVIEW_SEEDED",
        text: """
        请用 memory_update 创建一个名为「Legacy Supplier Note」的 legacy_note 词条，summary 写「供应商状态需要人工复盘 REVIEW_UNRESOLVED」；再追加一个正文块，逐字写「未裁决：供应商状态同时被标为 active 和 terminated」。不要添加关系。工具成功后回复 BRAIN_REVIEW_SEEDED。
        """
      )

    assert_successful_operation!(seeded.messages, "create_entry")
    assert_successful_operation!(seeded.messages, "append_block")
    entry = brain_entry_by_name!(ctx.agent.uid, "Legacy Supplier Note")
    [conflict_block] = entry_blocks(entry.id)

    _latest_mention =
      record_source!(ctx,
        event_id: "evt_brain_review_latest_mention",
        message_id: "om_brain_review_latest_mention",
        chat_id: "oc_brain_review",
        offset_ms: @stale_review_offset_ms,
        text: "Legacy Supplier Note 仍在团队讨论中；这条新提及用于证明旧词条已经落后超过 90 天。"
      )

    review =
      addressed_turn!(ctx,
        event_id: "evt_brain_review_open",
        message_id: "om_brain_review_open",
        chat_id: "oc_brain_review",
        chat_type: "group",
        offset_ms: 41_000,
        marker: "BRAIN_REVIEW_WAITING_FOR_DECISION",
        text: """
        复盘一下你的记忆。必须先用 skill_view 加载 brain-review 技能，再按该技能先运行只读的 memory_health_check，然后用 memory_open 查看「Legacy Supplier Note」。此轮不要修改它，列出问题并等待我的裁决，然后回复 BRAIN_REVIEW_WAITING_FOR_DECISION。
        """
      )

    assert_tool_succeeded!(review.messages, "skill_view")
    health_output = successful_tool_output!(review.messages, "memory_health_check")
    assert health_output =~ entry.id
    assert health_output =~ conflict_block.id
    assert health_output =~ "unresolved_conflicts"
    assert health_output =~ "stale_entries"
    assert_tool_succeeded!(review.messages, "memory_open")
    assert_tool_order!(review.messages, ["skill_view", "memory_health_check", "memory_open"])
    refute tool_result_succeeded?(review.messages, "memory_update")

    decided =
      addressed_turn!(ctx,
        event_id: "evt_brain_review_decide",
        message_id: "om_brain_review_decide",
        chat_id: "oc_brain_review",
        chat_type: "group",
        offset_ms: 42_000,
        marker: "BRAIN_REVIEW_DECISION_APPLIED",
        text: """
        我的裁决是删除「Legacy Supplier Note」。请先 memory_open 取得当前 lock version，再用 memory_update 的 delete_entry 执行。工具成功后回复 BRAIN_REVIEW_DECISION_APPLIED。
        """
      )

    assert_tool_succeeded!(decided.messages, "memory_open")
    assert_successful_operation!(decided.messages, "delete_entry")
    refute Repo.get(BrainEntry, entry.id)

    audit =
      AuditLog
      |> where([log], log.entry_id == ^entry.id and log.action == "delete_entry")
      |> order_by([log], desc: log.inserted_at)
      |> Repo.one!()

    assert map_value(audit.before, "kind") == "entry_bundle"
    assert map_value(map_value(audit.before, "entry"), "name") == "Legacy Supplier Note"

    assert Enum.any?(map_value(audit.before, "blocks"), fn block ->
             map_value(block, "id") == conflict_block.id
           end)

    %{entry: entry, audit: audit, turns: [seeded, review, decided]}
  end

  @doc "A skill-specific correction persists in the overlay and is visible on the next load."
  def run_skill_learning(ctx) do
    learned =
      addressed_turn!(ctx,
        event_id: "evt_brain_skill_learn",
        message_id: "om_brain_skill_learn",
        chat_id: "oc_brain_skill_dm_1",
        chat_type: "p2p",
        offset_ms: 50_000,
        marker: "BRAIN_SKILL_LEARNED",
        text: """
        我纠正你的 nano-pdf 工作方式：情境「交付编辑后的 PDF」→ 注意点「必须逐页渲染检查，标识 PDF_RENDER_EVERY_PAGE」。这是技能专属经验。先用 skill_view 读取 nano-pdf，再按现有重合度选择 skill_append 或 skill_replace 写入一次。工具成功后回复 BRAIN_SKILL_LEARNED。
        """
      )

    assert_tool_succeeded!(learned.messages, "skill_view")

    assert_tool_succeeded!(learned.messages, "skill_append")
    refute tool_result_succeeded?(learned.messages, "skill_replace")

    assert %AgentSkillOverlay{overlay_json: %{"text" => overlay}, content_hash: content_hash} =
             AgentSkillOverlay
             |> where([row], row.agent_uid == ^ctx.agent.uid and row.skill_name == "nano-pdf")
             |> where([row], is_nil(row.deleted_at))
             |> Repo.one!()

    assert overlay =~ "PDF_RENDER_EVERY_PAGE"
    assert is_binary(content_hash) and content_hash != ""

    loaded =
      addressed_turn!(ctx,
        event_id: "evt_brain_skill_reload",
        message_id: "om_brain_skill_reload",
        chat_id: "oc_brain_skill_dm_2",
        chat_type: "p2p",
        offset_ms: 51_000,
        marker: "BRAIN_SKILL_RELOADED",
        text: """
        这是新的会话。请用 skill_view 重新加载 nano-pdf，并只根据加载到的技能说明确认上次的 PDF 交付注意点，然后回复 BRAIN_SKILL_RELOADED。
        """
      )

    assert successful_tool_output!(loaded.messages, "skill_view") =~ "PDF_RENDER_EVERY_PAGE"

    %{overlay: overlay, turns: [learned, loaded]}
  end

  @doc "Recalling a cited source deletes only dependent blocks and leaves a recoverable audit snapshot."
  def run_retraction(ctx) do
    source =
      record_source!(ctx,
        event_id: "evt_brain_retract_source",
        message_id: "om_brain_retract_source",
        chat_id: "oc_brain_retraction",
        offset_ms: 60_000,
        text: "Project Ember 的临时访问码是 EMBER_SOURCE_ONLY_942。"
      )

    assert {:ok, scope} = Scope.for_store(ctx.agent.uid, "public")
    actor = %{kind: :agent, uid: ctx.agent.uid}

    assert {:ok, %{results: [%{entry_id: entry_id, entry_lock_version: 1}]}} =
             Knowledge.apply_operations(
               scope,
               %{
                 operation: "create_entry",
                 name: "Project Ember Access",
                 type: "access_policy",
                 summary: "Project Ember access facts"
               },
               actor,
               metadata: %{"surface" => "brain_real_llm_e2e_fixture"}
             )

    assert {:ok, %{results: [%{entry_lock_version: 2}]}} =
             Knowledge.apply_operations(
               scope,
               %{
                 operation: "append_block",
                 entry_id: entry_id,
                 expected_entry_lock_version: 1,
                 body: "EMBER_SOURCE_ONLY_942 src:#{source.document_id}"
               },
               actor,
               metadata: %{"surface" => "brain_real_llm_e2e_fixture"}
             )

    assert {:ok, %{results: [%{entry_lock_version: 3}]}} =
             Knowledge.apply_operations(
               scope,
               %{
                 operation: "append_block",
                 entry_id: entry_id,
                 expected_entry_lock_version: 2,
                 body: "Ember 由安全团队管理 UNCITED_EMBER_OWNER"
               },
               actor,
               metadata: %{"surface" => "brain_real_llm_e2e_fixture"}
             )

    entry = brain_entry_by_name!(ctx.agent.uid, "Project Ember Access")
    blocks = entry_blocks(entry.id)
    assert length(blocks) == 2

    cited = Enum.find(blocks, &String.contains?(&1.body, "src:#{source.document_id}"))
    uncited = Enum.find(blocks, &String.contains?(&1.body, "UNCITED_EMBER_OWNER"))
    assert %EntryBlock{} = cited
    assert %EntryBlock{} = uncited

    assert :ok =
             FakeFeishu.State.user_recalls_message(ctx.fake_feishu.state,
               event_id: "evt_brain_retract_remove",
               message_id: source.source_entry_id,
               chat_id: "oc_brain_retraction",
               chat_type: "group",
               to_app: record_app_id(),
               recall_time_ms: DateTime.to_unix(at(62_000), :millisecond)
             )

    assert wait_for_event_ack!(ctx.fake_feishu, "evt_brain_retract_remove") == 200
    assert :ok = wait_for_signal_entry_removed!(source.signal_channel_id, source.source_entry_id)

    withdrawal_job =
      Repo.one!(
        from(job in Job,
          where: job.worker == ^Oban.Worker.to_string(WithdrawSource),
          where: fragment("?->>'document_id' = ?", job.args, ^source.document_id)
        )
      )

    assert withdrawal_job.queue == "default"
    assert withdrawal_job.state == "available"

    other_available_job_ids =
      Repo.all(
        from(job in Job,
          where:
            job.queue == "default" and job.state == "available" and
              job.id != ^withdrawal_job.id,
          order_by: [asc: job.id],
          select: job.id
        )
      )

    acceptance_queue = "brain_retraction_e2e_#{withdrawal_job.id}"

    assert {1, nil} =
             Repo.update_all(
               from(job in Job,
                 where:
                   job.id == ^withdrawal_job.id and job.queue == "default" and
                     job.state == "available"
               ),
               set: [queue: acceptance_queue]
             )

    assert %{
             cancelled: 0,
             discard: 0,
             failure: 0,
             snoozed: 0,
             success: 1
           } =
             Oban.drain_queue(
               queue: acceptance_queue,
               with_limit: 1,
               with_safety: false
             )

    assert Repo.get!(Job, withdrawal_job.id).state == "completed"

    assert Repo.all(
             from(job in Job,
               where: job.id in ^other_available_job_ids and job.state == "available",
               order_by: [asc: job.id],
               select: job.id
             )
           ) == other_available_job_ids

    assert {:ok, audit} =
             wait_until(deadline(30_000), fn ->
               cited_deleted = is_nil(Repo.get(EntryBlock, cited.id))
               uncited_present = match?(%EntryBlock{}, Repo.get(EntryBlock, uncited.id))

               if cited_deleted and uncited_present do
                 AuditLog
                 |> where([log], log.block_id == ^cited.id and log.action == "delete_block")
                 |> order_by([log], desc: log.inserted_at)
                 |> Repo.one()
               end
             end)

    assert map_value(audit.before, "body") == cited.body
    assert map_value(audit.before, "body") =~ "src:#{source.document_id}"

    checked =
      addressed_turn!(ctx,
        event_id: "evt_brain_retract_check",
        message_id: "om_brain_retract_check",
        chat_id: "oc_brain_retraction",
        chat_type: "group",
        offset_ms: 63_000,
        marker: "BRAIN_RETRACTION_VERIFIED",
        text: """
        请用 memory_open 打开「Project Ember Access」，只按当前投影确认撤回后的剩余内容，然后回复 BRAIN_RETRACTION_VERIFIED。
        """
      )

    open_output = successful_tool_output!(checked.messages, "memory_open")
    assert open_output =~ "UNCITED_EMBER_OWNER"
    refute open_output =~ "EMBER_SOURCE_ONLY_942"

    %{entry: entry, deleted_block: cited, preserved_block: uncited, audit: audit}
  end

  # -- real-path helpers -----------------------------------------------------

  defp ensure_lark_group_joined!(ctx, chat_id) do
    assert {:ok, _group} =
             IMGroups.ensure_lark_im_group(
               "lark-main",
               chat_id,
               %{
                 "name" => "Brain dreaming E2E",
                 "app_id" => primary_app_id(),
                 "domain" => "feishu",
                 "raw_payload" => %{"chat_id" => chat_id, "name" => "Brain dreaming E2E"}
               },
               AdapterContext.new(
                 agent_uid: ctx.agent.uid,
                 binding_name: ctx.primary_binding.name,
                 adapter: "lark",
                 user_name: "Lark"
               )
             )
  end

  defp addressed_turn!(ctx, opts) do
    event_id = Keyword.fetch!(opts, :event_id)
    message_id = Keyword.fetch!(opts, :message_id)
    chat_id = Keyword.fetch!(opts, :chat_id)
    chat_type = Keyword.fetch!(opts, :chat_type)
    marker = Keyword.fetch!(opts, :marker)
    mention = lark_bot_mention()

    assert :ok =
             FakeFeishu.State.user_sends_message(ctx.fake_feishu.state,
               event_id: event_id,
               message_id: message_id,
               chat_id: chat_id,
               chat_type: chat_type,
               sender_user_id: Keyword.get(opts, :sender_user_id, "ou_alice"),
               sender_open_id: Keyword.get(opts, :sender_open_id, "ou_open_alice"),
               text: "@_user_1 " <> Keyword.fetch!(opts, :text),
               mentions: [mention],
               to_app: primary_app_id(),
               create_time_ms:
                 DateTime.to_unix(at(Keyword.fetch!(opts, :offset_ms)), :millisecond)
             )

    input = actor_event_by_source_entry_id!(ctx.agent.uid, message_id)

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_event_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, reply, message} =
             wait_for_completed_final_reply(ctx.container, input.id, deadline(300_000))

    messages = ai_messages_for_actor_event(input.id)

    assert is_binary(reply.text) and String.contains?(reply.text, marker),
           "expected final reply marker #{marker}, got #{inspect(reply.text)}; tool journal=#{inspect(tool_results(messages), limit: :infinity, printable_limit: :infinity)}"

    assert_actor_event_completed!(input.id)
    assert_lark_final_reply(ctx.fake_feishu, reply, marker, :reply, message_id)

    outbox = final_outbox!(input.id, message.id)
    assert outbox.status == :succeeded
    assert outbox.created_source_entry_id == reply.source_entry_id

    %{input: input, reply: reply, message: message, messages: messages, outbox: outbox}
  end

  defp record_source!(ctx, opts) do
    event_id = Keyword.fetch!(opts, :event_id)
    message_id = Keyword.fetch!(opts, :message_id)
    chat_id = Keyword.fetch!(opts, :chat_id)

    assert :ok =
             FakeFeishu.State.user_sends_message(ctx.fake_feishu.state,
               event_id: event_id,
               message_id: message_id,
               chat_id: chat_id,
               chat_type: "group",
               text: Keyword.fetch!(opts, :text),
               mentions: [],
               to_app: record_app_id(),
               create_time_ms:
                 DateTime.to_unix(at(Keyword.fetch!(opts, :offset_ms)), :millisecond)
             )

    assert wait_for_event_ack!(ctx.fake_feishu, event_id) == 200
    wait_for_signal_entry!("lark:#{chat_id}", message_id)
  end

  defp final_outbox!(actor_event_id, message_id) do
    Repo.one!(
      from(outbox in OutboxEntry,
        where: outbox.source_actor_event_id == ^actor_event_id,
        where: outbox.ai_message_id == ^message_id,
        where: outbox.outbound_key == ^"ai-reply:#{message_id}"
      )
    )
  end

  defp brain_entry_by_name!(owner_uid, name) do
    Repo.one!(
      from(entry in BrainEntry,
        where: entry.owner_uid == ^owner_uid and entry.name == ^name
      )
    )
  end

  defp brain_entry_count(owner_uid, name) do
    Repo.aggregate(
      from(entry in BrainEntry,
        where: entry.owner_uid == ^owner_uid and entry.name == ^name
      ),
      :count
    )
  end

  defp entry_blocks(entry_id) do
    EntryBlock
    |> where([block], block.entry_id == ^entry_id)
    |> order_by([block], asc: block.position, asc: block.id)
    |> Repo.all()
  end

  defp entry_text(%BrainEntry{} = entry) do
    [entry.summary | Enum.map(entry_blocks(entry.id), & &1.body)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp successful_operation_count(messages, operation) do
    messages
    |> tool_results("memory_update")
    |> Enum.count(fn result ->
      not tool_result_error?(result) and result.arguments["operation"] == operation
    end)
  end

  defp assert_successful_operation!(messages, operation) do
    assert successful_operation_count(messages, operation) > 0,
           "expected successful memory_update operation=#{operation}, got #{inspect(tool_results(messages, "memory_update"), limit: :infinity)}"
  end

  defp refute_successful_operation!(messages, operation) do
    assert successful_operation_count(messages, operation) == 0,
           "unexpected successful memory_update operation=#{operation}"
  end

  defp assert_successful_memory_update!(messages) do
    assert Enum.any?(tool_results(messages, "memory_update"), &(not tool_result_error?(&1)))
  end

  defp assert_tool_succeeded!(messages, tool_name) do
    assert tool_result_succeeded?(messages, tool_name),
           "expected successful #{tool_name}, got #{inspect(tool_results(messages, tool_name), limit: :infinity)}"
  end

  defp assert_tool_arguments!(messages, tool_name, expected) do
    assert Enum.any?(tool_results(messages, tool_name), fn
             %{arguments: arguments} when is_map(arguments) ->
               Enum.all?(expected, fn {key, value} -> arguments[key] == value end)

             _result ->
               false
           end),
           "expected #{tool_name} arguments to include #{inspect(expected)}, got #{inspect(tool_results(messages, tool_name), limit: :infinity)}"
  end

  defp assert_tool_order!(messages, expected) do
    actual =
      messages
      |> function_call_items()
      |> Enum.map(& &1["name"])
      |> Enum.filter(&(&1 in expected))
      |> Enum.uniq()

    assert actual == expected,
           "expected tool order #{inspect(expected)}, got #{inspect(actual)} from #{inspect(function_call_items(messages), limit: :infinity)}"
  end

  defp successful_tool_output!(messages, tool_name) do
    assert_tool_succeeded!(messages, tool_name)

    messages
    |> successful_tool_results(tool_name)
    |> inspect(limit: :infinity, printable_limit: :infinity)
  end

  defp dreaming_block_count(owner_uid) do
    Repo.aggregate(
      from(block in EntryBlock,
        where: block.owner_uid == ^owner_uid and block.author_kind == :dreaming
      ),
      :count
    )
  end

  defp dreaming_audit_count(owner_uid) do
    Repo.aggregate(
      from(log in AuditLog,
        where: log.owner_uid == ^owner_uid and log.actor_kind == :dreaming
      ),
      :count
    )
  end

  defp map_value(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        Enum.find_value(map, fn
          {candidate, value} when is_atom(candidate) ->
            if Atom.to_string(candidate) == key, do: {:found, value}

          _entry ->
            nil
        end)
        |> case do
          {:found, value} -> value
          nil -> nil
        end
    end
  end

  defp map_value(_map, _key), do: nil

  defp at(offset_ms), do: DateTime.add(@base_time, offset_ms, :millisecond)
end
