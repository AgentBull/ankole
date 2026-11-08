# Run in a disposable MIX_TEST_PARTITION with mix run --no-start --no-compile.
import ExUnit.Assertions
alias Ankole.Repo
alias Ankole.Ecto.UUIDv7
Application.ensure_all_started(:ecto_sql)
Application.ensure_all_started(:postgrex)
:ok = Ecto.Adapters.Postgres.storage_up(Repo.config())

{:ok, :verified, _} =
  Ecto.Migrator.with_repo(Repo, fn repo ->
    Ecto.Migrator.run(repo, Ankole.Migrations.paths(), :up, to: 20_261_102_020_000, log: false)
    [[tenant]] = repo.query!("SELECT id::text FROM tenants ORDER BY id LIMIT 1").rows
    ordinary = UUIDv7.autogenerate()
    mixed = UUIDv7.autogenerate()
    collision = UUIDv7.autogenerate()
    managed = UUIDv7.autogenerate()
    source = UUIDv7.autogenerate()
    old = ~U[2026-08-01 00:00:00.000000Z]
    now = ~U[2026-10-01 00:00:00.000000Z]

    insert_page = fn id, slug, body ->
      repo.query!(
        "INSERT INTO brain_objects (tenant_id,id,slug,type,title,body,meta,created_at,updated_at) VALUES ($1::text::uuid,$2::text::uuid,$3,'company',$3,$4,'{}',$5,$6)",
        [tenant, id, slug, body, old, now]
      )
    end

    insert_page.(ordinary, "companies/plain", "Current ordinary evidence.")

    insert_page.(
      mixed,
      "companies/mixed",
      "Public current.\n\n{% audience scope=\"principal:system\" %}\nPrivate current.\n{% /audience %}\n"
    )

    insert_page.(collision, "companies/mixed/system", "Real child with colliding source name.")

    repo.query!(
      "INSERT INTO brain_sources (tenant_id,id,kind,upstream_id,name,default_audience_scope) VALUES ($1::text::uuid,$2::text::uuid,'oidc_client','migration-client','Source','principal:system')",
      [tenant, source]
    )

    insert_page.(managed, "media/managed", "Managed source evidence.")

    repo.query!(
      "UPDATE brain_objects SET managed_by_source_id=$3::text::uuid,meta=$4::jsonb WHERE tenant_id=$1::text::uuid AND id=$2::text::uuid",
      [
        tenant,
        managed,
        source,
        %{
          "conversation_id" => "upstream-conversation",
          "source_revision" => 9,
          "audience_scope" => "principal:system",
          "summary" => "Business summary"
        }
      ]
    )

    for {id, body} <- [
          {ordinary, "Ordinary historical evidence."},
          {mixed,
           "Public history.\n{% audience scope=\"principal:system\" %}\nPrivate historical secret.\n{% /audience %}"}
        ] do
      repo.query!(
        "INSERT INTO brain_object_versions (tenant_id,id,object_id,body,meta,snapshot_at) VALUES ($1::text::uuid,$2::text::uuid,$3::text::uuid,$4,'{}',$5)",
        [tenant, UUIDv7.autogenerate(), id, body, old]
      )
    end

    for {slug, scope} <- [{"companies/plain", "world"}, {"companies/mixed", "principal:system"}] do
      repo.query!(
        "INSERT INTO brain_claims (tenant_id,id,claim_type,object_slug,claim,kind,holder,audience_scope,notability,confidence,valid_from,provenance) VALUES ($1::text::uuid,$2::text::uuid,'fact',$3,'Migrated assertion','fact','world',$4,'medium',0.75,$5,'migration acceptance')",
        [tenant, UUIDv7.autogenerate(), slug, scope, old]
      )
    end

    repo.query!(
      "INSERT INTO brain_links (tenant_id,id,from_object_slug,to_object_slug,link_type,context) VALUES ($1::text::uuid,$2::text::uuid,'companies/plain','companies/mixed','supplies','typed relation')",
      [tenant, UUIDv7.autogenerate()]
    )

    repo.query!(
      "INSERT INTO brain_object_aliases (tenant_id,id,object_slug,alias_norm) VALUES ($1::text::uuid,$2::text::uuid,'companies/plain','plain company')",
      [tenant, UUIDv7.autogenerate()]
    )

    brain_id = UUIDv7.autogenerate()

    repo.query!(
      """
      INSERT INTO drive_nodes(tenant_id,id,parent_id,name,kind,acl_anchor_id,inherit_permissions,
        has_local_acl,mode,created_at,updated_at)
      SELECT tenant_id,$2::text::uuid,id,'AnkoleBrain','folder',acl_anchor_id,true,false,420,now(),now()
      FROM drive_nodes WHERE tenant_id=$1::text::uuid AND parent_id IS NULL
        AND private_owner_uid IS NULL AND conversation_id IS NULL
      """,
      [tenant, brain_id]
    )

    repo.query!(
      """
      INSERT INTO pages(tenant_id,id,title,created_at,updated_at) VALUES($1::text::uuid,$2::text::uuid,'AnkoleBrain',now(),now())
      """,
      [tenant, brain_id]
    )

    alias Ankole.AIAgent.Library.{Contracts, SourceReader}
    owner = "migration-owner@example.com"

    repo.query!(
      "INSERT INTO principals (tenant_id,uid,type,status,membership,display_name,inserted_at,updated_at) VALUES ($1::text::uuid,$2,'human','active','member','Owner',$3,$3)",
      [tenant, owner, now]
    )

    default_documents = %{
      "SOUL.md" => SourceReader.load_default_soul_template(),
      "MISSION.md" => SourceReader.load_default_mission_template(),
      "DESIGN.md" => SourceReader.load_default_design_template(),
      "ConfidentialityPolicy.md" => SourceReader.load_default_confidentiality_policy_template()
    }

    custom_documents =
      Map.merge(default_documents, %{
        "SOUL.md" => "Custom identity",
        "MISSION.md" => "",
        "DESIGN.md" => "",
        "ConfidentialityPolicy.md" => "Do not publish customer pricing."
      })

    personal_documents =
      Map.merge(default_documents, %{
        "SOUL.md" => SourceReader.load_personal_assistant_template("SOUL.md"),
        "MISSION.md" => SourceReader.load_personal_assistant_template("MISSION.md")
      })

    for {uid, type, documents} <- [
          {"migration-default", "ai_colleague", default_documents},
          {"migration-custom", "ai_colleague", custom_documents},
          {"migration-personal", "personal_assistant", personal_documents}
        ] do
      repo.query!(
        "INSERT INTO principals (tenant_id,uid,type,status,display_name,inserted_at,updated_at) VALUES ($1::text::uuid,$2,'agent','active',$2,$3,$3)",
        [tenant, uid, now]
      )

      repo.query!(
        "INSERT INTO agents (tenant_id,uid,type,role,owner_principal_uid,inserted_at,updated_at) VALUES ($1::text::uuid,$2,$3::agent_type,'Migration role',$4,$5,$5)",
        [tenant, uid, type, owner, now]
      )

      for {path, content} <- documents do
        kind =
          %{
            "SOUL.md" => "soul",
            "MISSION.md" => "mission",
            "DESIGN.md" => "design",
            "ConfidentialityPolicy.md" => "confidentiality_policy"
          }[path]

        repo.query!(
          "INSERT INTO agent_library_container_entries (tenant_id,id,agent_uid,path,source_kind,content,content_hash,inserted_at,updated_at) VALUES ($1::text::uuid,$2::text::uuid,$3,$4,$5,$6,$7,$8,$8)",
          [
            tenant,
            UUIDv7.autogenerate(),
            uid,
            path,
            kind,
            content,
            SourceReader.hash(content),
            now
          ]
        )
      end
    end

    {:ok, sources} = Ankole.AIAgent.Library.shipped_skill_sources()
    builtin = Enum.find(sources, &(is_nil(&1.metadata["agent_plugin_id"]) and &1.default_enabled))

    for {uid, enabled} <- [{"migration-default", false}, {"migration-custom", true}] do
      repo.query!(
        "INSERT INTO agent_skills(tenant_id,id,agent_uid,skill_name,source_kind,relative_path,enabled_override,default_enabled,description,content_hash,inserted_at,updated_at) VALUES($1::text::uuid,$2::text::uuid,$3,$4,'builtin',$4,$5,true,'Legacy shipped Skill','old',now(),now())",
        [tenant, UUIDv7.autogenerate(), uid, builtin.name, enabled]
      )
    end

    Ankole.Migrations.migrate(repo, Ankole.Migrations.paths(), :up, all: true, log: false)

    assert [[false, state]] =
             repo.query!("SELECT enabled_for_all,upstream_state FROM skills WHERE slug=$1", [
               builtin.name
             ]).rows

    assert state["upstream_base_hash"] == builtin.source_hash

    assert [["migration-custom"], ["migration-personal"]] =
             repo.query!(
               "SELECT b.agent_uid FROM agent_skills b JOIN skills s ON s.id=b.skill_id AND s.tenant_id=b.tenant_id WHERE s.slug=$1 ORDER BY b.agent_uid",
               [builtin.name]
             ).rows

    assert [[nil, nil]] =
             repo.query!(
               "SELECT to_regclass('brain_objects'),to_regclass('brain_object_versions')"
             ).rows

    assert [] = repo.query!("SELECT name FROM brain_schema_types WHERE name='agent-skills'").rows

    assert [[ordinary_xml]] =
             repo.query!("SELECT content FROM page_snapshots WHERE page_id=$1::text::uuid", [
               ordinary
             ]).rows

    assert ordinary_xml =~ "Ordinary historical evidence"

    assert [[metadata, upstream]] =
             repo.query!(
               "SELECT metadata,upstream_state FROM pages WHERE id=$1::text::uuid",
               [managed]
             ).rows

    assert metadata["summary"] == "Business summary"
    refute Map.has_key?(metadata, "source_revision")
    refute Map.has_key?(metadata, "audience_scope")
    refute Map.has_key?(metadata, "conversation_id")
    assert upstream["source_id"] == source
    assert upstream["source_revision"] == 9
    assert upstream["conversation_id"] == "upstream-conversation"
    assert is_binary(upstream["source_node_id"])

    assert [[mixed_xml, "baseline"]] =
             repo.query!(
               "SELECT content,reason FROM page_snapshots WHERE page_id=$1::text::uuid",
               [mixed]
             ).rows

    assert mixed_xml =~ "Public current"
    refute mixed_xml =~ "Private"

    assert [[private_id, "system (2)"]] =
             repo.query!(
               "SELECT n.id::text,n.name FROM pages n JOIN page_contents c ON c.page_id=n.id AND c.tenant_id=n.tenant_id WHERE n.parent_id=$1::text::uuid AND c.plain_text LIKE '%Private current%'",
               [mixed]
             ).rows

    assert [[false]] =
             repo.query!("SELECT inherit_permissions FROM pages WHERE id=$1::text::uuid", [
               private_id
             ]).rows

    assert [[0]] =
             repo.query!(
               "SELECT count(*) FROM page_snapshots WHERE content LIKE '%Private historical secret%'"
             ).rows

    assert [[^mixed, ^private_id]] =
             repo.query!(
               "SELECT subject_page_id::text,source_node_id::text FROM brain_claims WHERE subject_page_id=$1::text::uuid",
               [mixed]
             ).rows

    assert [[^ordinary, ^mixed, "supplies"]] =
             repo.query!(
               "SELECT from_page_id::text,to_page_id::text,link_type FROM brain_links WHERE link_type='supplies'"
             ).rows

    assert [["plain company"]] =
             repo.query!(
               "SELECT alias_norm FROM brain_object_aliases WHERE subject_page_id=$1::text::uuid",
               [ordinary]
             ).rows

    assert [[1]] =
             repo.query!("SELECT count(*) FROM pages WHERE system_key='ankole_brain'").rows

    Ankole.Migrations.migrate(repo, Ankole.Migrations.paths(), :up, all: true, log: false)

    canonical = fn content ->
      {:ok, parsed} = Ankole.Kernel.knowledge_parse(content)
      {:ok, output} = Ankole.Kernel.knowledge_export(parsed.xml, parsed.metadata)
      output
    end

    Repo.with_tenant(tenant, fn ->
      for {uid, documents, private?} <- [
            {"migration-default", default_documents, false},
            {"migration-custom", custom_documents, false},
            {"migration-personal", personal_documents, true}
          ] do
        {:ok, effective} = Contracts.effective(uid)
        {:ok, local_agents} = Contracts.get(uid, :agents)
        {:ok, local_design} = Contracts.get(uid, :design)
        if uid == "migration-default", do: assert(is_nil(local_agents))
        if uid != "migration-custom", do: assert(is_nil(local_design))

        custom_confidentiality =
          if documents["ConfidentialityPolicy.md"] ==
               default_documents["ConfidentialityPolicy.md"],
             do: "",
             else: documents["ConfidentialityPolicy.md"]

        prior_agents =
          [documents["SOUL.md"], documents["MISSION.md"], custom_confidentiality]
          |> Enum.reject(&(String.trim(&1) == ""))
          |> Enum.join("\n\n")

        assert effective["agents"]["content"] == canonical.(prior_agents)
        assert effective["design"]["content"] == canonical.(documents["DESIGN.md"])
        {:ok, agents} = Ankole.Brain.Namespace.system_node("ankole_brain_agents")
        {:ok, page} = Ankole.Brain.Namespace.child(agents.id, uid)
        assert page.inherit_permissions == not private?

        if uid == "migration-default",
          do: assert(Ankole.Pod.Pages.Tree.list_children(page.id) == [])
      end

      {:ok, root} = Ankole.Brain.Namespace.root()
      refute root.inherit_permissions
    end)

    assert [[nil]] = repo.query!("SELECT to_regclass('agent_library_container_entries')").rows
    :verified
  end)

IO.puts("KNOWLEDGE_MIGRATION_VERIFIED")
