defmodule Ankole.DriveMigrationTest.Repo do
  use Ecto.Repo, otp_app: :ankole, adapter: Ecto.Adapters.Postgres
end

defmodule Ankole.DriveMigrationTest do
  use ExUnit.Case, async: false
  alias Ankole.DriveMigrationTest.{Fixture, Repo}
  @moduletag timeout: 120_000
  @migrations Path.expand("../priv/repo/migrations", __DIR__)
  @version 20_261_030_120_000

  setup do
    connection =
      Ankole.Repo.config()
      |> Keyword.take([:hostname, :port, :username, :password, :ssl, :socket_options, :types])
      |> Keyword.put(:database, "postgres")

    {:ok, admin} = Postgrex.start_link(connection)
    database = "ankole_drive_migration_#{System.system_time(:microsecond)}"
    Postgrex.query!(admin, "CREATE DATABASE #{database} TEMPLATE template0", [])
    GenServer.stop(admin)
    opts = Keyword.merge(connection, database: database, pool_size: 4, log: false)
    start_supervised!({Repo, opts})

    on_exit(fn ->
      {:ok, cleanup} = Postgrex.start_link(connection)
      Postgrex.query!(cleanup, "DROP DATABASE #{database} WITH (FORCE)", [])
      GenServer.stop(cleanup)
    end)

    Ecto.Migrator.run(Repo, @migrations, :up, to: 20_261_030_060_000, log: false)
    :ok
  end

  test "a fresh database migrates to the only Drive tree and reference schema" do
    migrate!()

    assert [[nil, nil]] =
             Repo.query!("SELECT to_regclass('drive_files'),to_regclass('files')").rows

    assert [[0]] =
             Repo.query!(
               "SELECT count(*) FROM information_schema.columns WHERE table_name='pages' AND column_name IN ('parent_id','type','private_owner_uid','acl_anchor_id','deleted_at')"
             ).rows

    assert [[1]] =
             Repo.query!(
               "SELECT count(*) FROM drive_nodes WHERE parent_id IS NULL AND private_owner_uid IS NULL AND conversation_id IS NULL"
             ).rows

    assert [[0]] = Repo.query!("SELECT count(*) FROM file_objects").rows
  end

  test "upgrade preserves page permissions and references while isolating shared bytes by tenant" do
    {:ok, f} = Repo.transaction(fn -> Fixture.seed(Repo) end)

    on_exit(fn ->
      Ankole.ObjectStore.delete("blobs/" <> f.hash)
      Ankole.ObjectStore.delete("blobs/" <> f.orphan)
    end)

    [public, child | _] = f.page_ids
    file_page = f.filepage

    Repo.query!("UPDATE pages SET parent_id=$1 WHERE tenant_id=$2 AND id=$3", [
      file_page,
      f.tenant,
      child
    ])

    error = assert_raise RuntimeError, ~r/File Pages have child nodes/, &migrate!/0
    assert error.message =~ Ecto.UUID.load!(file_page)
    assert error.message =~ Ecto.UUID.load!(child)
    assert [["drive_files"]] = Repo.query!("SELECT to_regclass('drive_files')::text").rows

    Repo.query!("UPDATE pages SET parent_id=$1 WHERE tenant_id=$2 AND id=$3", [
      public,
      f.tenant,
      child
    ])

    invalid = Ecto.UUID.dump!(Ankole.Ecto.UUIDv7.autogenerate())

    Repo.query!(
      "INSERT INTO permission_grants(tenant_id,id,principal_uid,resource_pattern,action,condition,inserted_at,updated_at) VALUES($1,$2,$3,'pod:space:**','page_view','resource == \"pod:space:**\"',now(),now())",
      [f.tenant, invalid, f.alice]
    )

    assert_raise RuntimeError, ~r/refers to renamed resource\/action variables/, &migrate!/0
    assert [["drive_files"]] = Repo.query!("SELECT to_regclass('drive_files')::text").rows
    Repo.query!("DELETE FROM permission_grants WHERE id=$1", [invalid])

    for {uid, action} <- [
          {f.alice, "read"},
          {f.other_agent, "read"},
          {f.agent <> "*", "read"},
          {f.agent, "unsupported"}
        ] do
      Repo.query!(
        "INSERT INTO permission_grants(tenant_id,id,principal_uid,resource_pattern,action,condition,inserted_at,updated_at) VALUES($1,$2,$3,$4,$5,'true',now(),now())",
        [f.tenant, invalid, f.alice, "site_console:agent:#{uid}:files", action]
      )

      error = assert_raise RuntimeError, ~r/to one Agent in its tenant/, &migrate!/0
      assert error.message =~ Ecto.UUID.load!(invalid)
      assert [["drive_files"]] = Repo.query!("SELECT to_regclass('drive_files')::text").rows
      Repo.query!("DELETE FROM permission_grants WHERE id=$1", [invalid])
    end

    collision = Ecto.UUID.dump!(Ankole.Ecto.UUIDv7.autogenerate())

    Repo.query!(
      "INSERT INTO pages(tenant_id,id,private_owner_uid,type,title,position,inherit_permissions,has_local_acl,acl_anchor_id,created_by,created_at,updated_at) VALUES($1,$2,$3,'doc','notes.txt','a',true,false,$2,$4,now(),now())",
      [f.tenant, collision, f.agent, Ecto.UUID.load!(f.tenant) <> ":" <> f.alice]
    )

    Repo.query!(
      "INSERT INTO drive_files(tenant_id,agent_uid,path,sha256,mode,content_type,source,inserted_at,updated_at) VALUES($1,$2,'notes.txt',decode($3,'hex'),420,'text/plain','agent',now(),now())",
      [f.tenant, f.agent, f.hash]
    )

    migrate!()

    # These owners had no Pod private Page. Their new Drive roots need
    # the same owner permissions as roots created through Nodes.
    for {tenant, uid} <- [{f.other_tenant, f.other_agent}, {f.tenant, f.member}] do
      assert Enum.map(~w(node_comment node_contribute node_edit node_manage node_view), &[&1]) ==
               Repo.query!(
                 "SELECT action FROM permission_grants WHERE tenant_id=$1 AND principal_uid=$2 AND resource_pattern=$3 ORDER BY action",
                 [tenant, uid, "drive:private:#{uid}:**"]
               ).rows
    end

    assert [[0]] =
             Repo.query!(
               "SELECT count(*) FROM permission_grants WHERE tenant_id=$1 AND principal_uid=$2 AND resource_pattern='site_console:drive'",
               [f.tenant, f.alice]
             ).rows

    assert [["node_contribute"], ["node_edit"], ["node_view"]] ==
             Repo.query!(
               "SELECT action FROM permission_grants WHERE tenant_id=$1 AND principal_uid=$2 AND resource_pattern=$3 ORDER BY action",
               [f.tenant, f.alice, "drive:private:#{f.agent}:**"]
             ).rows

    assert [[1]] =
             Repo.query!(
               "SELECT count(*) FROM permission_grants WHERE tenant_id=$1 AND principal_uid=$2 AND resource_pattern='site_console:drive' AND action='read'",
               [f.tenant, f.guest]
             ).rows

    assert [["node_contribute", f.grant_at], ["node_edit", f.grant_at], ["node_view", f.grant_at]] ==
             Repo.query!(
               "SELECT action,inserted_at FROM permission_grants WHERE tenant_id=$1 AND group_id=$2 AND resource_pattern=$3 AND condition='principal.type == \"human\"' AND description='Scoped files' AND metadata=$4 AND updated_at=inserted_at ORDER BY action",
               [f.tenant, f.group, "drive:private:#{f.agent}:**", %{"origin" => "legacy"}]
             ).rows

    assert [[0]] =
             Repo.query!(
               "SELECT count(*) FROM permission_grants WHERE resource_pattern LIKE 'site_console:agent:%:files'"
             ).rows

    assert [["notes.txt", "doc"], ["notes.txt (2)", "file"]] ==
             Repo.query!(
               "SELECT name,kind FROM drive_nodes WHERE tenant_id=$1 AND name LIKE 'notes.txt%' ORDER BY name",
               [f.tenant]
             ).rows

    assert [[%{"type" => "plaintext", "value" => 45}]] =
             Repo.query!(
               "SELECT value FROM app_configurations WHERE tenant_id=$1 AND key='drive.trash_retention_days'",
               [f.tenant]
             ).rows

    assert [["Ankole.Files.Jobs.PurgeNode", %{"node_id" => node_id}]] =
             Repo.query!(
               "SELECT worker,args FROM oban_jobs WHERE args->>'tenant_id'=$1 AND args ? 'node_id'",
               [Ecto.UUID.load!(f.tenant)]
             ).rows

    assert node_id == Ecto.UUID.load!(f.private)

    objects =
      Repo.query!(
        "SELECT tenant_id,id,storage_key,encode(sha256,'hex'),size FROM file_objects ORDER BY tenant_id"
      ).rows

    assert length(objects) == 2
    assert objects |> Enum.map(&Enum.at(&1, 2)) |> Enum.uniq() |> length() == 2

    for [_tenant, _id, key, hash, size] <- objects do
      assert hash == f.hash
      assert size == byte_size(f.bytes)
      assert {:ok, f.bytes} == Ankole.ObjectStore.read(key)
      on_exit(fn -> Ankole.ObjectStore.delete(key) end)
    end

    assert Enum.count(objects, &(Enum.at(&1, 2) == "blobs/" <> f.hash)) == 1
    object = objects |> Enum.find(&(hd(&1) == f.tenant)) |> Enum.at(1)
    other_object = objects |> Enum.find(&(hd(&1) == f.other_tenant)) |> Enum.at(1)

    assert [[8]] =
             Repo.query!(
               "SELECT count(*) FROM drive_nodes WHERE tenant_id=$1 AND id=ANY($2::uuid[])",
               [f.tenant, f.page_ids]
             ).rows

    assert [[true, nil]] =
             Repo.query!(
               "SELECT inherit_permissions,private_owner_uid FROM drive_nodes WHERE tenant_id=$1 AND id=$2",
               [f.tenant, f.private]
             ).rows

    assert [[0]] =
             Repo.query!(
               "SELECT count(*) FROM drive_nodes WHERE tenant_id=$1 AND private_owner_uid=$2",
               [f.tenant, f.guest]
             ).rows

    assert [[object]] ==
             Repo.query!("SELECT object_id FROM drive_nodes WHERE tenant_id=$1 AND id=$2", [
               f.tenant,
               f.filepage
             ]).rows

    assert [[3]] =
             Repo.query!("SELECT count(*) FROM pod_files WHERE tenant_id=$1", [f.tenant]).rows

    assert [["metadata/custom-emoji/migration.png"]] =
             Repo.query!("SELECT path FROM pod_files WHERE tenant_id=$1 AND node_id IS NULL", [
               f.tenant
             ]).rows

    assert [["src/main.ts"]] =
             Repo.query!("SELECT path FROM pod_files WHERE tenant_id=$1 AND node_id=$2", [
               f.tenant,
               f.applet
             ]).rows

    assert [["same   title"], ["same   title (2)"]] =
             Repo.query!(
               "SELECT name FROM drive_nodes WHERE tenant_id=$1 AND name LIKE 'same%' ORDER BY name",
               [f.tenant]
             ).rows

    assert [[^object, node, %{"attachment_id" => 7}], [nil, nil, %{"resolution" => "pending"}]] =
             Repo.query!(
               "SELECT object_id,node_id,metadata FROM message_attachments WHERE tenant_id=$1 AND message_id=$2 ORDER BY position",
               [f.tenant, f.message]
             ).rows

    assert is_binary(node)

    assert [[f.conversation]] ==
             Repo.query!(
               "SELECT root.conversation_id FROM drive_nodes n JOIN drive_nodes root ON root.tenant_id=n.tenant_id AND root.id=n.parent_id WHERE n.tenant_id=$1 AND n.id=$2",
               [f.tenant, node]
             ).rows

    assert [[f.agent]] ==
             Repo.query!(
               "WITH RECURSIVE ancestors AS (SELECT * FROM drive_nodes WHERE tenant_id=$1 AND name='private.txt' UNION ALL SELECT p.* FROM drive_nodes p JOIN ancestors c ON c.tenant_id=p.tenant_id AND c.parent_id=p.id) SELECT private_owner_uid FROM ancestors WHERE parent_id IS NULL",
               [f.tenant]
             ).rows

    assert [["pending", ^object], ["sent", nil]] =
             Repo.query!(
               "SELECT outbound_key,object_id FROM delivery_attachments WHERE tenant_id=$1 ORDER BY outbound_key",
               [f.tenant]
             ).rows

    assert [[0]] =
             Repo.query!("SELECT count(*) FROM deliveries WHERE payload ? 'attachments'").rows

    [[content, metadata]] =
      Repo.query!(
        "SELECT content,metadata FROM ai_gateway_messages WHERE tenant_id=$1 AND id=$2",
        [f.tenant, f.ai_message]
      ).rows

    assert metadata == f.metadata
    [reply, user_message, other_tool] = content
    assert user_message == f.user_message
    assert other_tool == f.other_tool
    [attachment] = JSON.decode!(reply["output"])["attachments"]
    assert attachment["object_id"] == Ecto.UUID.load!(object)
    refute Map.has_key?(attachment, "blob_ref")
    assert attachment["provider_metadata"] == %{"blob_ref" => f.orphan}

    for [producer, data, extensions] <-
          Repo.query!("SELECT producer,data,extensions FROM signals WHERE tenant_id=$1", [
            f.tenant
          ]).rows do
      assert extensions == f.raw_payload

      if producer == "kernel" do
        assert get_in(data, ["entry", "attachments", Access.at(0), "object_id"]) ==
                 Ecto.UUID.load!(object)

        assert get_in(data, ["entry", "reply_to", "attachments", Access.at(0), "object_id"]) ==
                 Ecto.UUID.load!(object)

        assert data["entry"]["text"] == f.system_data["entry"]["text"]
        assert data["entry"]["metadata"] == f.raw_payload
      else
        assert data == f.system_data
      end
    end

    [[entries]] =
      Repo.query!("SELECT entries FROM conversation_inbound_batches WHERE tenant_id=$1", [
        f.tenant
      ]).rows

    assert get_in(entries, [Access.at(0), "attachments", Access.at(0), "object_id"]) ==
             Ecto.UUID.load!(object)

    assert hd(entries)["metadata"] == f.raw_payload

    assert [[f.raw_payload, f.raw_payload]] ==
             Repo.query!(
               "SELECT metadata,raw_payload FROM external_message_refs WHERE tenant_id=$1",
               [f.tenant]
             ).rows

    assert [
             [%{"raw" => f.raw_payload, "text" => "outbound"}, f.raw_payload],
             [%{"raw" => f.raw_payload, "text" => "outbound"}, f.raw_payload]
           ] ==
             Repo.query!("SELECT payload,recovery_state FROM deliveries WHERE tenant_id=$1", [
               f.tenant
             ]).rows

    [[compaction]] =
      Repo.query!("SELECT content FROM ai_gateway_compaction_artifacts WHERE tenant_id=$1", [
        f.tenant
      ]).rows

    assert compaction["output"] == content
    assert compaction["retention"] == f.raw_payload

    assert [[1]] =
             Repo.query!(
               "SELECT count(*) FROM oban_jobs WHERE worker='Ankole.Files.Jobs.DeleteObject' AND args->>'storage_key'=$1",
               ["blobs/" <> f.orphan]
             ).rows

    assert {:ok, _} = Ankole.ObjectStore.read("blobs/" <> f.orphan)

    assert_raise Postgrex.Error, ~r/foreign key/, fn ->
      Repo.query!("UPDATE drive_nodes SET object_id=$3 WHERE tenant_id=$1 AND id=$2", [
        f.tenant,
        f.filepage,
        other_object
      ])
    end

    assert_raise Postgrex.Error, ~r/foreign key/, fn ->
      Repo.query!("DELETE FROM file_objects WHERE tenant_id=$1 AND id=$2", [f.tenant, object])
    end

    assert_raise Postgrex.Error, ~r/Native messages require text or an attachment/, fn ->
      Repo.query!("DELETE FROM message_attachments WHERE tenant_id=$1 AND message_id=$2", [
        f.tenant,
        f.message
      ])
    end

    Repo.query!("DELETE FROM drive_nodes WHERE tenant_id=$1 AND id=$2", [f.tenant, node])

    assert [[f.tenant, nil, object]] ==
             Repo.query!(
               "SELECT tenant_id,node_id,object_id FROM message_attachments WHERE tenant_id=$1 AND message_id=$2 AND position=0",
               [f.tenant, f.message]
             ).rows
  end

  defp migrate! do
    Ecto.Migrator.run(Repo, @migrations, :up, to: @version, log: false)
  end
end

defmodule Ankole.DriveMigrationTest.Fixture do
  def seed(repo) do
    q = fn sql, params -> repo.query!(sql, params) end
    id = fn -> Ecto.UUID.dump!(Ankole.Ecto.UUIDv7.autogenerate()) end

    [
      a,
      b,
      public,
      child,
      isolated,
      private,
      trashed,
      under_trash,
      filepage,
      applet,
      conversation,
      message,
      group,
      computed
    ] = for _ <- 1..14, do: id.()

    uid = "migration_" <> Base.encode16(:crypto.strong_rand_bytes(5), case: :lower)
    alice = uid <> "_alice"
    member = uid <> "_member"
    guest = uid <> "_guest"
    agent = uid <> "_agent"
    other = uid <> "_other"

    for {tenant, slug} <- [{a, uid <> "-a"}, {b, uid <> "-b"}] do
      q.(
        "INSERT INTO tenants(id,slug,display_name,base_db_id,inserted_at,updated_at) VALUES($1,$2,$2,'migration',now(),now())",
        [tenant, String.replace(slug, "_", "-")]
      )
    end

    for {tenant, principal, type, membership} <- [
          {a, alice, "human", "member"},
          {a, member, "human", "member"},
          {a, guest, "human", "guest"},
          {a, agent, "agent", nil},
          {b, other, "agent", nil}
        ] do
      q.(
        "INSERT INTO principals(tenant_id,uid,type,membership,display_name,inserted_at,updated_at) VALUES($1,$2,$3,$4,$2,now(),now())",
        [tenant, principal, type, membership]
      )
    end

    for {pid, parent, owner, kind, title, position, inherit, local, anchor, parent_anchor,
         deleted} <- [
          {public, nil, nil, "doc", "same / title", "a", true, false, public, nil, false},
          {child, public, nil, "doc", "子页面", "a", true, false, public, nil, false},
          {isolated, nil, nil, "doc", "same / title", "b", false, true, isolated, nil, false},
          {private, nil, alice, "doc", "private", "a", false, true, private, nil, false},
          {trashed, nil, nil, "doc", "trash", "c", true, false, trashed, nil, true},
          {under_trash, trashed, nil, "doc", "hidden", "a", true, false, trashed, nil, false},
          {filepage, nil, nil, "file", "photo.png", "d", true, false, filepage, nil, false},
          {applet, nil, nil, "applet", "app", "e", true, false, applet, nil, false}
        ] do
      q.(
        "INSERT INTO pages(tenant_id,id,parent_id,private_owner_uid,type,title,position,inherit_permissions,has_local_acl,acl_anchor_id,parent_anchor_id,deleted_at,created_by,created_at,updated_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,CASE WHEN $12 THEN now() END,$13,now(),now())",
        [
          a,
          pid,
          parent,
          owner,
          kind,
          title,
          position,
          inherit,
          local,
          anchor,
          parent_anchor,
          deleted,
          Ecto.UUID.load!(a) <> ":" <> alice
        ]
      )
    end

    q.(
      "INSERT INTO principal_groups(tenant_id,id,name,display_name,kind,computed_condition,inserted_at,updated_at) VALUES($1,$2,'migration_static','Migration','static',NULL,now(),now()),($1,$3,'migration_computed','Computed','computed','principal.type == \"agent\"',now(),now())",
      [a, group, computed]
    )

    q.(
      "INSERT INTO principal_group_memberships(tenant_id,principal_uid,group_id,inserted_at) VALUES($1,$2,$3,now())",
      [a, alice, group]
    )

    grants = [
      {alice, nil, nil, nil, "pod:space:**", "page_view", nil, nil, "true"},
      {nil, group, nil, nil, "pod:space:**", "page_edit", nil, nil, "true"},
      {nil, computed, nil, nil, "pod:space:**", "page_write_records", nil, nil, "true"},
      {alice, nil, nil, nil, "pod:private:#{alice}:**", "page_manage", nil, nil, "true"},
      {alice, nil, nil, nil, "pod:private:#{agent}:**", "page_view", nil, nil, "true"},
      {guest, nil, nil, nil, "pod:private:#{alice}:**", "page_view", nil, nil, "true"},
      {guest, nil, nil, nil, "pod:**:#{Ecto.UUID.load!(isolated)}:page", "page_view", isolated,
       "self", "true"},
      {nil, nil, public, "page_view", "pod:**:#{Ecto.UUID.load!(isolated)}:**", "page_edit",
       isolated, "container", "true"},
      {agent, nil, nil, nil, "pod:**:#{Ecto.UUID.load!(private)}:page", "page_comment", private,
       "self", "principal.type == \"agent\""}
    ]

    for {principal, gid, source, source_action, pattern, action, target, scope, condition} <-
          grants do
      q.(
        "INSERT INTO permission_grants(tenant_id,id,principal_uid,group_id,source_page_id,source_action,resource_pattern,action,target_page_id,target_scope,condition,inserted_at,updated_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,now(),now())",
        [
          a,
          id.(),
          principal,
          gid,
          source,
          source_action,
          pattern,
          action,
          target,
          scope,
          condition
        ]
      )
    end

    q.(
      "INSERT INTO conversations(tenant_id,id,title,created_by,last_activity_at,inserted_at,updated_at,room_mode,native_access_scope) VALUES($1,$2,'Migration',$3,now(),now(),now(),'group','participants')",
      [a, conversation, alice]
    )

    for action <- ["read", "update", "delete"] do
      q.(
        "INSERT INTO permission_grants(tenant_id,id,principal_uid,resource_pattern,action,condition,inserted_at,updated_at) VALUES($1,$2,$3,$4,$5,'true',now(),now())",
        [a, id.(), alice, "site_console:agent:#{agent}:files", action]
      )
    end

    for pattern <- ["site_console:files", "site_console:agent:*:files"] do
      q.(
        "INSERT INTO permission_grants(tenant_id,id,principal_uid,resource_pattern,action,condition,inserted_at,updated_at) VALUES($1,$2,$3,$4,'read','true',now(),now())",
        [a, id.(), guest, pattern]
      )
    end

    grant_at = ~N[2026-09-01 01:02:03.000000]

    q.(
      "INSERT INTO permission_grants(tenant_id,id,group_id,resource_pattern,action,condition,description,metadata,inserted_at,updated_at) VALUES($1,$2,$3,$4,'update','principal.type == \"human\"','Scoped files',$5,$6,$6)",
      [a, id.(), group, "site_console:agent:#{agent}:files", %{"origin" => "legacy"}, grant_at]
    )

    q.(
      "INSERT INTO app_configurations(tenant_id,scope,key,value,inserted_at,updated_at) VALUES($1,$3,'pod.trash_retention_days',$2,now(),now())",
      [a, %{"type" => "plaintext", "value" => 45}, "tenant:" <> Ecto.UUID.load!(a)]
    )

    q.(
      "INSERT INTO oban_jobs(queue,worker,args,inserted_at,scheduled_at) VALUES('default','Ankole.Pod.Jobs.PurgePage',$1,now(),now())",
      [%{"tenant_id" => Ecto.UUID.load!(a), "page_id" => Ecto.UUID.load!(private)}]
    )

    bytes = "Migration shared bytes " <> uid
    hash = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    orphan = Base.encode16(:crypto.hash(:sha256, "unreferenced " <> uid), case: :lower)
    :ok = Ankole.ObjectStore.write("blobs/" <> hash, bytes)
    :ok = Ankole.ObjectStore.write("blobs/" <> orphan, "unreferenced " <> uid)

    q.("INSERT INTO files(sha256,size) VALUES(decode($1,'hex'),$2),(decode($3,'hex'),$4)", [
      hash,
      byte_size(bytes),
      orphan,
      byte_size("unreferenced " <> uid)
    ])

    for {tenant, owner, path} <- [
          {a, agent, "chats/#{Ecto.UUID.load!(conversation)}/private.txt"},
          {b, other, "shared.txt"},
          {a, nil, "pages/#{Ecto.UUID.load!(filepage)}/file/photo.png"},
          {a, nil, "pages/#{Ecto.UUID.load!(applet)}/src/main.ts"},
          {a, nil, "pages/#{Ecto.UUID.load!(public)}/images/report.png"},
          {a, nil, "metadata/custom-emoji/migration.png"}
        ] do
      q.(
        "INSERT INTO drive_files(tenant_id,agent_uid,path,sha256,mode,content_type,source,inserted_at,updated_at) VALUES($1,$2,$3,decode($4,'hex'),420,'text/plain','agent',now(),now())",
        [tenant, owner, path, hash]
      )
    end

    attachment = %{
      "blob_ref" => hash,
      "name" => "report.txt",
      "attachment_id" => 7,
      "path" => "chats/#{Ecto.UUID.load!(conversation)}/report.txt",
      "provider_metadata" => %{"blob_ref" => orphan}
    }

    raw_payload = %{
      "blob_ref" => orphan,
      "attachments" => [attachment],
      "example" => JSON.encode!(attachment)
    }

    entry = %{
      "attachments" => [attachment],
      "text" => JSON.encode!(raw_payload),
      "metadata" => raw_payload,
      "reply_to" => %{"attachments" => [attachment]}
    }

    system_data = %{"entry" => entry, "entries" => [entry]}

    for {producer, index} <- [{"kernel", 1}, {"external", 2}] do
      q.(
        "INSERT INTO signals(tenant_id,id,agent_uid,source,session_id,source_event_id,type,available_at,queue_sequence,occurred_at,inserted_at,updated_at,producer,data,extensions) VALUES($1,$2,$3,'migration','migration',$4,'conversation.message.addressed',now(),$5,now(),now(),now(),$6,$7,$8)",
        [a, id.(), agent, "signal-#{index}", index, producer, system_data, raw_payload]
      )
    end

    q.(
      "INSERT INTO conversation_inbound_batches(tenant_id,id,agent_uid,binding_name,session_id,policy,entries,available_at,inserted_at,updated_at,conversation_id) VALUES($1,$2,$3,'migration','migration','may_intervene',$4,now(),now(),now(),$5)",
      [a, id.(), agent, [entry], conversation]
    )

    q.(
      "INSERT INTO conversation_messages(tenant_id,id,conversation_id,seq,author_type,author_uid,author_display_name,text,attachments,created_at) VALUES($1,$2,$3,1,'human',$4,$4,NULL,$5,now())",
      [
        a,
        message,
        conversation,
        alice,
        [attachment, %{"resolution" => "pending", "name" => "pending"}]
      ]
    )

    q.(
      "INSERT INTO external_message_refs(tenant_id,message_id,conversation_id,provider_message_id,metadata,raw_payload,first_seen_at,last_seen_at) VALUES($1,$2,$3,'migration',$4,$4,now(),now())",
      [a, message, conversation, raw_payload]
    )

    for {key, status} <- [{"pending", "pending"}, {"sent", "sent"}] do
      payload = %{"text" => "outbound", "attachments" => [attachment], "raw" => raw_payload}

      q.(
        "INSERT INTO deliveries(tenant_id,agent_uid,binding_name,outbound_key,operation,status,payload,conversation_id,recovery_state,inserted_at,updated_at) VALUES($1,$2,'migration',$3,'post',$4,$5,$6,$7,now(),now())",
        [a, agent, key, status, payload, conversation, raw_payload]
      )
    end

    ai_conversation = id.()
    ai_message = id.()

    q.(
      "INSERT INTO ai_gateway_conversations(tenant_id,id,subject_uid,conversation_key,inserted_at,updated_at) VALUES($1,$2,$3,'migration',now(),now())",
      [a, ai_conversation, agent]
    )

    output = JSON.encode!(%{"tool" => "reply_attachment", "attachments" => [attachment]})
    # Even a real old digest in user-owned JSON must neither acquire a new
    # object nor be rewritten. Only the application's attachment slot migrates.
    user_message = %{
      "type" => "message",
      "role" => "user",
      "content" => [
        %{"type" => "input_text", "text" => ~s({ "blob_ref": "customer-key", "keep": true })},
        %{"type" => "input_text", "text" => JSON.encode!(%{"blob_ref" => orphan})},
        %{"type" => "input_text", "text" => output}
      ]
    }

    other_tool = %{
      "type" => "function_call_output",
      "call_id" => "read-customer-data",
      "output" => output
    }

    metadata = %{"nested" => attachment, "example" => user_message}

    content = [
      %{"type" => "function_call_output", "call_id" => "reply-file", "output" => output},
      user_message,
      other_tool
    ]

    q.(
      "INSERT INTO ai_gateway_messages(tenant_id,id,subject_uid,conversation_id,type,status,content,metadata,inserted_at,updated_at) VALUES($1,$2,$3,$4,'message','complete',$5,$6,now(),now())",
      [
        a,
        ai_message,
        agent,
        ai_conversation,
        content,
        metadata
      ]
    )

    q.(
      "INSERT INTO ai_gateway_compaction_artifacts(tenant_id,id,subject_uid,conversation_id,content,inserted_at,updated_at) VALUES($1,$2,$3,$4,$5,now(),now())",
      [a, id.(), agent, ai_conversation, %{"output" => content, "retention" => raw_payload}]
    )

    # The system call can live in an earlier response row than its tool output.
    q.(
      "INSERT INTO ai_gateway_messages(tenant_id,id,subject_uid,conversation_id,type,status,content,metadata,inserted_at,updated_at) VALUES($1,$2,$3,$4,'message','complete',$5,'{}',now(),now())",
      [
        a,
        id.(),
        agent,
        ai_conversation,
        [
          %{"type" => "function_call", "name" => "reply_attachment", "call_id" => "reply-file"},
          %{"type" => "function_call", "name" => "read_file", "call_id" => "read-customer-data"}
        ]
      ]
    )

    %{
      tenant: a,
      other_tenant: b,
      alice: alice,
      member: member,
      guest: guest,
      agent: agent,
      other_agent: other,
      group: group,
      grant_at: grant_at,
      public: public,
      private: private,
      filepage: filepage,
      applet: applet,
      conversation: conversation,
      message: message,
      ai_message: ai_message,
      raw_payload: raw_payload,
      system_data: system_data,
      metadata: metadata,
      user_message: user_message,
      other_tool: other_tool,
      hash: hash,
      orphan: orphan,
      bytes: bytes,
      page_ids: [public, child, isolated, private, trashed, under_trash, filepage, applet]
    }
  end
end
