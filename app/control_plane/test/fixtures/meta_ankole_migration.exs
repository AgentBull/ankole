# Run with mix run --no-start in a fresh, disposable MIX_TEST_PARTITION.
import ExUnit.Assertions
alias Ankole.Repo
alias Ankole.Ecto.UUIDv7
Application.ensure_all_started(:ecto_sql)
Application.ensure_all_started(:postgrex)
:ok = Ecto.Adapters.Postgres.storage_up(Repo.config())

{:ok, :verified, _} =
  Ecto.Migrator.with_repo(Repo, fn repo ->
    Ecto.Migrator.run(repo, Ankole.Migrations.paths(), :up, to: 20_261_103_010_000, log: false)
    [[tenant]] = repo.query!("SELECT id::text FROM tenants ORDER BY id LIMIT 1").rows

    [[space]] =
      repo.query!(
        "SELECT id::text FROM pages WHERE tenant_id=$1::text::uuid AND parent_id IS NULL AND private_owner_uid IS NULL AND conversation_id IS NULL",
        [tenant]
      ).rows

    uid = "migration-agent"
    private_uid = "private@example.com"

    repo.query!(
      "INSERT INTO principals(tenant_id,uid,type,status,membership,display_name,inserted_at,updated_at) VALUES($1::text::uuid,'migration-owner','human','active','member','Owner',now(),now())",
      [tenant]
    )

    for agent <- [uid, private_uid] do
      repo.query!(
        "INSERT INTO principals(tenant_id,uid,type,status,display_name,inserted_at,updated_at) VALUES($1::text::uuid,$2,'agent','active',$2,now(),now())",
        [tenant, agent]
      )

      repo.query!(
        "INSERT INTO agents(tenant_id,uid,type,role,owner_principal_uid,inserted_at,updated_at) VALUES($1::text::uuid,$2,'ai_colleague','Migration agent','migration-owner',now(),now())",
        [tenant, agent]
      )
    end

    page = fn parent, name, xml, metadata, system ->
      existing =
        repo.query!(
          "SELECT id::text FROM pages WHERE tenant_id=$1::text::uuid AND parent_id=$2::text::uuid AND name=$3 AND deleted_at IS NULL",
          [tenant, parent, name]
        ).rows

      id =
        case existing do
          [[id]] -> id
          [] -> UUIDv7.autogenerate()
        end

      {:ok, projection} = Ankole.Kernel.vfs_projection(:knowledge, xml, metadata)

      if existing == [] do
        repo.query!(
          """
          INSERT INTO pages(tenant_id,id,type,name,title,parent_id,parent_anchor_id,acl_anchor_id,has_local_acl,system_key,metadata,vfs_content_empty,vfs_md_size,vfs_md_blake3)
          VALUES($1::text::uuid,$2::text::uuid,'knowledge',$3,$3,$4::text::uuid,$4::text::uuid,$2::text::uuid,true,$5,$6,$7,$8,$9)
          """,
          [
            tenant,
            id,
            name,
            parent,
            system,
            metadata,
            projection.vfs_content_empty,
            projection.vfs_md_size,
            projection.vfs_md_blake3
          ]
        )
      else
        repo.query!(
          "UPDATE pages SET metadata=$3,vfs_content_empty=$4,vfs_md_size=$5,vfs_md_blake3=$6 WHERE tenant_id=$1::text::uuid AND id=$2::text::uuid",
          [
            tenant,
            id,
            metadata,
            projection.vfs_content_empty,
            projection.vfs_md_size,
            projection.vfs_md_blake3
          ]
        )
      end

      repo.query!(
        "INSERT INTO page_contents(tenant_id,page_id,content,plain_text,updated_by,updated_at,contributors) VALUES($1::text::uuid,$2::text::uuid,$3,$3,'ankole:'||$1||':principal/migration-owner',now(),ARRAY[]::text[]) ON CONFLICT (page_id) DO UPDATE SET content=excluded.content,plain_text=excluded.plain_text",
        [tenant, id, xml]
      )

      id
    end

    brain =
      case repo.query!(
             "SELECT id::text FROM pages WHERE tenant_id=$1::text::uuid AND system_key='ankole_brain'",
             [tenant]
           ).rows do
        [[id]] -> id
        [] -> page.(space, "AnkoleBrain", "<page />", %{}, "ankole_brain")
      end

    agents = page.(brain, "agents", "<page />", %{}, "ankole_brain_agents")
    profile = page.(agents, uid, "<page><p>Identity</p></page>", %{}, nil)
    disabled_profile = page.(agents, private_uid, "<page><p>Past identity</p></page>", %{}, nil)

    repo.query!(
      "UPDATE principals SET status='disabled' WHERE tenant_id=$1::text::uuid AND uid=$2",
      [tenant, private_uid]
    )

    global = page.(brain, "AGENTS.md", "<page><p>Global rules</p></page>", %{}, nil)
    append = page.(profile, "AGENTS.md", "<page><p>Shadowed append</p></page>", %{}, nil)

    override =
      page.(profile, "AGENTS.override.md", "<page><p>Chosen override</p></page>", %{}, nil)

    notes = page.(brain, "notes", "<page />", %{}, nil)

    knowledge =
      page.(
        notes,
        "evidence",
        "<page><p>Keep this evidence</p></page>",
        %{"entity_type" => "note"},
        nil
      )

    ordinary = page.(space, "ordinary", "<page><p>Collaboration</p></page>", %{}, nil)
    skills = page.(brain, "skills", "<page />", %{}, "ankole_brain_skills")

    skill =
      page.(
        skills,
        "migration-skill",
        "<page><p>Read references/details.md</p></page>",
        %{
          "name" => "migration-skill",
          "description" => "Migration package",
          "default_enabled" => true
        },
        nil
      )

    references = page.(skill, "references", "<page />", %{}, nil)
    reference = page.(references, "details", "<page><p>On-demand reference</p></page>", %{}, nil)
    chapter = page.(skill, "chapter.md", "<page><p>Chapter body</p></page>", %{}, nil)
    page.(chapter, "nested", "<page><p>Nested chapter</p></page>", %{}, nil)
    page.(skill, "duplicate", "<page><p>Duplicate body</p></page>", %{}, nil)

    legacy = fn agent, kind, override ->
      id = UUIDv7.autogenerate()

      repo.query!(
        """
        INSERT INTO agent_skills(tenant_id,id,agent_uid,skill_name,source_kind,relative_path,enabled_override,default_enabled,description,content_hash,inserted_at,updated_at)
        VALUES($1::text::uuid,$2::text::uuid,$3,'migration-skill',$4,'migration-skill',$5,true,'Migration package','old',now(),now())
        """,
        [tenant, id, agent, kind, override]
      )

      id
    end

    legacy.(uid, "shared", false)

    positive =
      page.(
        skills,
        "Renamed Page",
        "<page><p>Explicit enable</p></page>",
        %{
          "name" => "positive-skill",
          "description" => "Positive binding",
          "default_enabled" => true
        },
        nil
      )

    repo.query!(
      "INSERT INTO agent_skills(tenant_id,id,agent_uid,skill_name,source_kind,relative_path,enabled_override,default_enabled,description,content_hash,inserted_at,updated_at) VALUES($1::text::uuid,$2::text::uuid,$3,'positive-skill','shared','Renamed Page',true,true,'Positive binding','old',now(),now())",
      [tenant, UUIDv7.autogenerate(), uid]
    )

    installed_id = legacy.(private_uid, "installed", true)
    private_root = UUIDv7.autogenerate()

    repo.query!(
      "INSERT INTO pages(tenant_id,id,type,name,title,private_owner_uid,acl_anchor_id,has_local_acl) VALUES($1::text::uuid,$2::text::uuid,'doc','Private','Private',$3,$2::text::uuid,true)",
      [tenant, private_root, private_uid]
    )

    private_skills = page.(private_root, "skills", "<page />", %{}, nil)
    private_package = page.(private_skills, "migration-skill", "<page />", %{}, nil)
    binary = <<0, 1, 255, 42>>

    file = fn parent, name, bytes ->
      object_id = UUIDv7.autogenerate()
      key = "tenants/#{tenant}/objects/#{object_id}"
      {:ok, stored} = Ankole.ObjectStore.write_stream(key, [bytes])

      hash =
        if byte_size(stored.sha256) == 64,
          do: Base.decode16!(stored.sha256, case: :mixed),
          else: stored.sha256

      repo.query!(
        "INSERT INTO file_objects(tenant_id,id,storage_key,sha256,size,created_at,completed_at) VALUES($1::text::uuid,$2::text::uuid,$3,$4,$5,now(),now())",
        [tenant, object_id, key, hash, stored.size]
      )

      id = UUIDv7.autogenerate()

      repo.query!(
        "INSERT INTO pages(tenant_id,id,type,name,title,parent_id,parent_anchor_id,acl_anchor_id,has_local_acl,object_id,content_type,mode) VALUES($1::text::uuid,$2::text::uuid,'file',$3,$3,$4::text::uuid,$4::text::uuid,$2::text::uuid,true,$5::text::uuid,'application/octet-stream',420)",
        [tenant, id, name, parent, object_id]
      )

      object_id
    end

    file.(
      private_package,
      "SKILL.md",
      "---\nname: migration-skill\ndescription: \n---\nPrivate instructions\n"
    )

    incomplete = page.(private_skills, "incomplete", "<page />", %{}, nil)
    retained_file = file.(incomplete, "notes.txt", "Package in progress")

    repo.query!(
      "INSERT INTO agent_skills(tenant_id,id,agent_uid,skill_name,source_kind,relative_path,enabled_override,default_enabled,description,content_hash,inserted_at,updated_at) VALUES($1::text::uuid,$2::text::uuid,$3,'incomplete','installed','incomplete',true,false,'Package in progress','old',now(),now())",
      [tenant, UUIDv7.autogenerate(), private_uid]
    )

    scripts = page.(private_package, "scripts", "<page />", %{}, nil)
    repo.query!("UPDATE pages SET type='doc' WHERE id=$1::text::uuid", [scripts])
    script_id = file.(scripts, "run.sh", "#!/bin/sh\necho migrated\n")
    manifest_attachment = file.(skill, "SKILL.md", "An independent attachment")

    binary_id = file.(skill, "template.bin", binary)
    file.(skill, "duplicate.md", "Original companion file")

    deleted = fn id ->
      repo.query!("UPDATE pages SET deleted_at=now() WHERE id=$1::text::uuid", [id])
    end

    obsolete_override =
      page.(profile, "DESIGN.override.md", "<page><p>Deleted override</p></page>", %{}, nil)

    deleted.(obsolete_override)
    page.(profile, "DESIGN.md", "<page><p>Live design</p></page>", %{}, nil)
    orphan = page.(agents, "removed-agent", "<page />", %{}, nil)
    orphan_contract = page.(orphan, "AGENTS.md", "<page><p>Orphan contract</p></page>", %{}, nil)

    removed_skill =
      page.(skills, "recreated-skill", "<page><p>Deleted package</p></page>", %{}, nil)

    deleted.(removed_skill)
    page.(removed_skill, "hidden-child", "<page><p>Also deleted</p></page>", %{}, nil)

    replacement_skill =
      page.(skills, "recreated-skill", "<page><p>Live package</p></page>", %{}, nil)

    removed_reference =
      page.(references, "discarded", "<page><p>Deleted reference</p></page>", %{}, nil)

    deleted.(removed_reference)
    page.(skills, "UPPER Legacy", "<page><p>Legacy name</p></page>", %{}, nil)
    page.(skills, "private-example.com-migration-skill", "<page />", %{}, nil)
    page.(skills, "imported-" <> installed_id, "<page />", %{}, nil)

    Ankole.Migrations.migrate(repo, Ankole.Migrations.paths(), :up, all: true, log: false)

    assert [[true]] =
             repo.query!("SELECT enabled_for_all FROM skills WHERE id=$1::text::uuid", [positive]).rows

    assert [[^uid]] =
             repo.query!("SELECT agent_uid FROM agent_skills WHERE skill_id=$1::text::uuid", [
               positive
             ]).rows

    assert [["positive-skill"]] =
             repo.query!("SELECT slug FROM skills WHERE id=$1::text::uuid", [positive]).rows

    assert [[1]] =
             repo.query!(
               "SELECT count(*) FROM pages WHERE object_id=$1::text::uuid AND deleted_at IS NULL",
               [retained_file]
             ).rows

    assert [["C"]] =
             repo.query!(
               "SELECT c.collname FROM pg_attribute a JOIN pg_collation c ON c.oid=a.attcollation WHERE a.attrelid='pages'::regclass AND a.attname='position'"
             ).rows

    assert [["scripts/run.sh"]] =
             repo.query!("SELECT relative_path FROM skill_files WHERE object_id=$1::text::uuid", [
               script_id
             ]).rows

    assert [[attachment_path]] =
             repo.query!("SELECT relative_path FROM skill_files WHERE object_id=$1::text::uuid", [
               manifest_attachment
             ]).rows

    assert String.starts_with?(attachment_path, "SKILL.attachment-")

    assert [] ==
             repo.query!("SELECT id FROM agent_contracts WHERE agent_uid='removed-agent'").rows

    assert [] ==
             repo.query!("SELECT id FROM pages WHERE id=$1::text::uuid", [orphan_contract]).rows

    assert [["append", live_design]] =
             repo.query!(
               "SELECT mode,content_markdown FROM agent_contracts WHERE agent_uid=$1 AND slot='design'",
               [uid]
             ).rows

    assert live_design =~ "Live design"
    refute live_design =~ "Deleted override"

    assert [[^replacement_skill]] =
             repo.query!("SELECT id::text FROM skills WHERE slug='recreated-skill'").rows

    assert [["upper-legacy"]] ==
             repo.query!("SELECT slug FROM skills WHERE name='UPPER Legacy'").rows

    assert [] ==
             repo.query!(
               "SELECT id FROM skill_files WHERE relative_path='references/discarded.md'"
             ).rows

    assert [[nil, brain]] ==
             repo.query!("SELECT parent_id,id::text FROM pages WHERE id=$1::text::uuid", [brain]).rows

    assert [[%{"entity_type" => "agent", "subtype" => "internal", "uid" => ^uid}]] =
             repo.query!("SELECT metadata FROM pages WHERE id=$1::text::uuid", [profile]).rows

    assert [[%{"archived" => true, "uid" => ^private_uid}]] =
             repo.query!("SELECT metadata FROM pages WHERE id=$1::text::uuid", [disabled_profile]).rows

    for id <- [profile, disabled_profile] do
      [[xml, metadata, size, hash]] =
        repo.query!(
          "SELECT c.content,p.metadata,p.vfs_md_size,p.vfs_md_blake3 FROM pages p JOIN page_contents c ON c.tenant_id=p.tenant_id AND c.page_id=p.id WHERE p.id=$1::text::uuid",
          [id]
        ).rows

      {:ok, projection} = Ankole.Kernel.vfs_projection(:knowledge, xml, metadata)
      assert {size, hash} == {projection.vfs_md_size, projection.vfs_md_blake3}
    end

    assert [["knowledge"]] ==
             repo.query!("SELECT type FROM pages WHERE id=$1::text::uuid", [knowledge]).rows

    assert [["doc"]] ==
             repo.query!("SELECT type FROM pages WHERE id=$1::text::uuid", [ordinary]).rows

    for removed <- [
          skills,
          skill,
          reference,
          references,
          global,
          append,
          override,
          private_package
        ] do
      assert [] == repo.query!("SELECT id FROM pages WHERE id=$1::text::uuid", [removed]).rows
    end

    assert [["override", body]] =
             repo.query!(
               "SELECT mode,content_markdown FROM agent_contracts WHERE tenant_id=$1::text::uuid AND agent_uid=$2 AND slot='agents'",
               [tenant, uid]
             ).rows

    assert body =~ "Chosen override"
    refute body =~ "Shadowed append"

    assert [[false]] ==
             repo.query!("SELECT enabled_for_all FROM skills WHERE id=$1::text::uuid", [skill]).rows

    assert [] ==
             repo.query!(
               "SELECT agent_uid FROM agent_skills WHERE skill_id=$1::text::uuid AND agent_uid=$2",
               [skill, uid]
             ).rows

    assert [[installed_slug]] =
             repo.query!(
               "SELECT slug FROM skills WHERE id IN (SELECT skill_id FROM agent_skills WHERE agent_uid=$1) AND source_kind='custom' AND id<>$2::text::uuid",
               [private_uid, skill]
             ).rows

    assert installed_slug == "imported-" <> installed_id <> "-1"

    assert [["migration-skill"]] =
             repo.query!("SELECT description FROM skills WHERE slug=$1", [installed_slug]).rows

    assert [[binary_id]] ==
             repo.query!(
               "SELECT object_id::text FROM skill_files WHERE skill_id=$1::text::uuid AND relative_path='template.bin'",
               [skill]
             ).rows

    [[reference_id]] =
      repo.query!(
        "SELECT object_id::text FROM skill_files WHERE skill_id=$1::text::uuid AND relative_path='references/details.md'",
        [skill]
      ).rows

    paths =
      repo.query!("SELECT relative_path FROM skill_files WHERE skill_id=$1::text::uuid", [skill]).rows
      |> List.flatten()

    refute Enum.any?(paths, fn path -> Enum.any?(paths, &String.starts_with?(&1, path <> "/")) end)

    assert "chapter.md._awiki.md" in paths
    assert "chapter.md/nested.md" in paths
    assert "duplicate._awiki.md" in paths
    assert "duplicate.md" in paths

    Repo.with_tenant(tenant, fn ->
      assert {:ok, ^binary} = Ankole.Files.read_object(binary_id)
      assert {:ok, reference_bytes} = Ankole.Files.read_object(reference_id)
      assert reference_bytes =~ "On-demand reference"

      for {path, expected} <- [
            {"chapter.md._awiki.md", "Chapter body"},
            {"chapter.md/nested.md", "Nested chapter"},
            {"duplicate._awiki.md", "Duplicate body"},
            {"duplicate.md", "Original companion file"}
          ] do
        [[object_id]] =
          repo.query!(
            "SELECT object_id::text FROM skill_files WHERE skill_id=$1::text::uuid AND relative_path=$2",
            [skill, path]
          ).rows

        assert {:ok, bytes} = Ankole.Files.read_object(object_id)
        assert bytes =~ expected
      end
    end)

    :verified
  end)

IO.puts(
  "Meta Ankole migration: IDs, contracts, bindings, private collisions, references and binary files verified"
)
