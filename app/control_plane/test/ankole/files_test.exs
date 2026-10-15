defmodule Ankole.FilesTest do
  use Ankole.DataCase, async: true

  import Ankole.PrincipalsFixtures

  alias Ankole.Files
  alias Ankole.Files.Jobs.CollectUnreferenced
  alias Ankole.Files.Schemas.AgentFile
  alias Ankole.Files.Schemas.Blob
  alias Ankole.ObjectStore

  setup do
    %{principal: agent} = agent_fixture()
    %{agent_uid: agent.uid}
  end

  describe "store/1" do
    test "stores one row and one object per content" do
      assert {:ok, %{sha256: sha256, size: 5}} = Files.store("hello")
      assert {:ok, %{sha256: ^sha256}} = Files.store("hello")

      digest = Base.decode16!(sha256, case: :lower)
      assert %Blob{size: 5, deleting: false} = Repo.get!(Blob, digest)
      assert {:ok, "hello"} = ObjectStore.read(Files.object_key(digest))
    end

    test "hashes and writes a local file" do
      path = Path.join(System.tmp_dir!(), "files-test-#{System.unique_integer([:positive])}")
      File.write!(path, "from a file")
      on_exit(fn -> File.rm(path) end)

      assert {:ok, %{sha256: sha256, size: 11}} = Files.store({:file, path})
      assert sha256 == Base.encode16(:crypto.hash(:sha256, "from a file"), case: :lower)
    end

    test "clears a deleting mark and writes the object again" do
      {:ok, %{sha256: sha256}} = Files.store("revived")
      digest = Base.decode16!(sha256, case: :lower)
      Repo.update_all(where(Blob, sha256: ^digest), set: [deleting: true])
      :ok = ObjectStore.delete(Files.object_key(digest))

      assert {:ok, _stored} = Files.store("revived")
      assert %Blob{deleting: false} = Repo.get!(Blob, digest)
      assert {:ok, "revived"} = ObjectStore.read(Files.object_key(digest))
    end
  end

  describe "commit/3" do
    test "subtree paths treat underscores and percent signs as literal characters", %{
      agent_uid: agent_uid
    } do
      {:ok, %{sha256: digest}} = Files.store("literal subtree")
      paths = ["a_b/x.txt", "a%b/y.txt", "axb/z.txt"]

      assert {:ok, _} =
               Files.commit(
                 agent_uid,
                 Enum.map(paths, &%{path: &1, sha256: digest, source: "agent"})
               )

      assert {:ok, %{deleted: 1}} = Files.commit(agent_uid, [], ["a_b"])
      assert {:ok, %{files: [file]}} = Files.list(agent_uid, "a%b")
      assert file.path == "a%b/y.txt"
      assert {:ok, %{files: remaining}} = Files.list(agent_uid)
      assert Enum.map(remaining, & &1.path) == ["a%b/y.txt", "axb/z.txt"]
    end

    test "names contents at paths and reads them back", %{agent_uid: agent_uid} do
      {:ok, %{sha256: report}} = Files.store("report body")
      {:ok, %{sha256: image}} = Files.store(<<137, 80, 78, 71>>)

      assert {:ok, %{files: [first, second], deleted: 0}} =
               Files.commit(agent_uid, [
                 %{path: "reports/q3.md", sha256: report, source: "agent"},
                 %{path: "inbox/abc/photo.png", sha256: image, source: "inbound", mode: 0o600}
               ])

      assert %AgentFile{path: "reports/q3.md", size: 11, content_type: "text/markdown"} = first
      assert %AgentFile{content_type: "image/png", mode: 0o600, size: 4} = second

      assert {:ok, %AgentFile{size: 11}, "report body"} = Files.read(agent_uid, "reports/q3.md")
      assert {:error, :not_found} = Files.fetch(agent_uid, "reports/missing.md")
    end

    test "replaces the file at an existing path", %{agent_uid: agent_uid} do
      {:ok, %{sha256: first}} = Files.store("v1")
      {:ok, %{sha256: second}} = Files.store("version two")

      {:ok, _files} =
        Files.commit(agent_uid, [%{path: "notes.txt", sha256: first, source: "agent"}])

      {:ok, %{files: [file]}} =
        Files.commit(agent_uid, [%{path: "notes.txt", sha256: second, source: "console"}])

      assert %AgentFile{source: "console", size: 11} = file
      assert {:ok, _file, "version two"} = Files.read(agent_uid, "notes.txt")
    end

    test "deletes paths and folders in the same transaction", %{agent_uid: agent_uid} do
      {:ok, %{sha256: sha256}} = Files.store("x")

      {:ok, _files} =
        Files.commit(agent_uid, [
          %{path: "jobs/10/a.txt", sha256: sha256, source: "agent"},
          %{path: "jobs/10/sub/b.txt", sha256: sha256, source: "agent"},
          %{path: "jobs/100/c.txt", sha256: sha256, source: "agent"}
        ])

      {:ok, %{files: [_file], deleted: 2}} =
        Files.commit(agent_uid, [%{path: "jobs/10/new.txt", sha256: sha256, source: "agent"}], [
          "jobs/10/sub",
          "jobs/10/a.txt"
        ])

      {:ok, %{files: files}} = Files.list(agent_uid)
      assert Enum.map(files, & &1.path) == ["jobs/10/new.txt", "jobs/100/c.txt"]
    end

    test "rejects a content that was never stored", %{agent_uid: agent_uid} do
      missing = String.duplicate("ab", 32)

      assert {:error, {:blob_missing, ^missing}} =
               Files.commit(agent_uid, [%{path: "a.txt", sha256: missing, source: "agent"}])

      assert {:ok, %{files: []}} = Files.list(agent_uid)
    end

    test "rejects a content that collection has marked", %{agent_uid: agent_uid} do
      {:ok, %{sha256: sha256}} = Files.store("being collected")
      digest = Base.decode16!(sha256, case: :lower)
      Repo.update_all(where(Blob, sha256: ^digest), set: [deleting: true])

      assert {:error, {:blob_missing, ^sha256}} =
               Files.commit(agent_uid, [%{path: "a.txt", sha256: sha256, source: "agent"}])
    end

    test "rejects invalid paths and sources", %{agent_uid: agent_uid} do
      {:ok, %{sha256: sha256}} = Files.store("x")

      for path <- ["", "/abs", "a//b", "a/../b", "trailing/", "./a", "nul\0byte"] do
        assert {:error, {:invalid_path, ^path}} =
                 Files.commit(agent_uid, [%{path: path, sha256: sha256, source: "agent"}])
      end

      assert {:error, {:invalid_source, "worker"}} =
               Files.commit(agent_uid, [%{path: "a", sha256: sha256, source: "worker"}])
    end

    test "rejects file and folder collisions within one commit", %{agent_uid: agent_uid} do
      {:ok, %{sha256: sha256}} = Files.store("tree conflict")

      assert {:error, {:path_conflict, "a", "a/b"}} =
               Files.commit(agent_uid, [
                 %{path: "a", sha256: sha256, source: "agent"},
                 %{path: "a/b", sha256: sha256, source: "agent"}
               ])

      assert {:ok, %{files: []}} = Files.list(agent_uid)
    end

    test "rejects an existing ancestor or descendant and rolls back deletes", %{
      agent_uid: agent_uid
    } do
      {:ok, %{sha256: sha256}} = Files.store("kept tree")

      assert {:ok, _files} =
               Files.commit(agent_uid, [
                 %{path: "a", sha256: sha256, source: "agent"},
                 %{path: "keep.txt", sha256: sha256, source: "agent"}
               ])

      assert {:error, {:path_conflict, "a", "a/b"}} =
               Files.commit(
                 agent_uid,
                 [%{path: "a/b", sha256: sha256, source: "agent"}],
                 ["keep.txt"]
               )

      assert {:ok, _file, "kept tree"} = Files.read(agent_uid, "keep.txt")
      assert {:ok, _file, "kept tree"} = Files.read(agent_uid, "a")

      assert {:ok, _files} =
               Files.commit(
                 agent_uid,
                 [%{path: "a/b", sha256: sha256, source: "agent"}],
                 ["a"]
               )

      assert {:error, {:path_conflict, "a", "a/b"}} =
               Files.commit(agent_uid, [%{path: "a", sha256: sha256, source: "agent"}])

      assert {:ok, _file, "kept tree"} = Files.read(agent_uid, "a/b")
      assert {:error, :not_found} = Files.fetch(agent_uid, "a")

      assert {:ok, %{deleted: 1}} =
               Files.commit(
                 agent_uid,
                 [%{path: "a", sha256: sha256, source: "agent"}],
                 ["a"]
               )
    end
  end

  describe "list/3" do
    test "lists a folder in path order with pagination", %{agent_uid: agent_uid} do
      {:ok, %{sha256: sha256}} = Files.store("x")

      upserts =
        for name <- ["skills/b/SKILL.md", "skills/a/SKILL.md", "skills/a/x.py", "skillset/z"] do
          %{path: name, sha256: sha256, source: "agent"}
        end

      {:ok, _files} = Files.commit(agent_uid, upserts)

      assert {:ok, %{files: page, next_after: "skills/a/x.py"}} =
               Files.list(agent_uid, "skills", limit: 2)

      assert Enum.map(page, & &1.path) == ["skills/a/SKILL.md", "skills/a/x.py"]

      assert {:ok, %{files: [%AgentFile{path: "skills/b/SKILL.md"}], next_after: nil}} =
               Files.list(agent_uid, "skills", limit: 2, after: "skills/a/x.py")
    end

    test "keeps drives of different Agents apart", %{agent_uid: agent_uid} do
      %{principal: other} = agent_fixture()
      {:ok, %{sha256: sha256}} = Files.store("shared bytes")
      {:ok, _} = Files.commit(agent_uid, [%{path: "a.txt", sha256: sha256, source: "inbound"}])
      {:ok, _} = Files.commit(other.uid, [%{path: "b.txt", sha256: sha256, source: "inbound"}])

      assert {:ok, %{files: [%AgentFile{path: "a.txt"}]}} = Files.list(agent_uid)
      assert {:error, :not_found} = Files.fetch(agent_uid, "b.txt")
      assert Repo.aggregate(Blob, :count) >= 1
    end
  end

  describe "list_children/3" do
    test "says when a folder has more children than the bound", %{agent_uid: agent_uid} do
      {:ok, %{sha256: sha256}} = Files.store("x")

      {:ok, _files} =
        Files.commit(agent_uid, [
          %{path: "inbox/a/one.png", sha256: sha256, source: "inbound"},
          %{path: "inbox/b/two.png", sha256: sha256, source: "inbound"},
          %{path: "inbox/c/three.png", sha256: sha256, source: "inbound"},
          %{path: "inbox/notes.txt", sha256: sha256, source: "agent"}
        ])

      assert {:ok, %{folders: ["a", "b", "c"], files: [%AgentFile{}], truncated: false}} =
               Files.list_children(agent_uid, "inbox")

      assert {:ok, %{folders: ["a", "b"], truncated: true}} =
               Files.list_children(agent_uid, "inbox", limit: 2)
    end
  end

  describe "move/4" do
    test "moves every file of a folder larger than one list page", %{agent_uid: agent_uid} do
      {:ok, %{sha256: sha256}} = Files.store("page")
      digest = Base.decode16!(sha256, case: :lower)
      now = DateTime.utc_now()

      rows =
        for index <- 1..5_001 do
          %{
            tenant_id: Repo.tenant_id!(),
            agent_uid: agent_uid,
            path: "jobs/1/node_modules/pkg-#{index}/index.js",
            sha256: digest,
            mode: 0o644,
            content_type: "text/javascript",
            source: "agent",
            inserted_at: now,
            updated_at: now
          }
        end

      for chunk <- Enum.chunk_every(rows, 1_000), do: Repo.insert_all(AgentFile, chunk)

      assert {:ok, 5_001} = Files.move(agent_uid, "jobs/1", "jobs/archived")
      assert Repo.aggregate(where(AgentFile, agent_uid: ^agent_uid), :count) == 5_001

      refute Repo.exists?(
               from(file in AgentFile,
                 where: file.agent_uid == ^agent_uid and like(file.path, "jobs/1/%")
               )
             )
    end

    test "moves a folder up into its parent without creating file ancestors",
         %{agent_uid: agent_uid} do
      {:ok, %{sha256: outer}} = Files.store("outer")
      {:ok, %{sha256: inner}} = Files.store("inner")

      {:ok, _files} =
        Files.commit(agent_uid, [
          %{path: "a/b/c", sha256: outer, source: "agent"},
          %{path: "a/b/d/e", sha256: inner, source: "agent"}
        ])

      assert {:ok, 2} = Files.move(agent_uid, "a/b", "a")
      assert {:ok, _file, "outer"} = Files.read(agent_uid, "a/c")
      assert {:ok, _file, "inner"} = Files.read(agent_uid, "a/d/e")
    end

    test "a move never turns an existing file into a folder or a folder into a file", %{
      agent_uid: agent_uid
    } do
      {:ok, %{sha256: sha256}} = Files.store("move conflict")

      assert {:ok, _files} =
               Files.commit(agent_uid, [
                 %{path: "from/x", sha256: sha256, source: "agent"},
                 %{path: "target", sha256: sha256, source: "agent"},
                 %{path: "folder/child", sha256: sha256, source: "agent"}
               ])

      assert {:error, {:path_conflict, "target", "target/x"}} =
               Files.move(agent_uid, "from", "target")

      assert {:error, {:path_conflict, "folder", "folder/child"}} =
               Files.move(agent_uid, "from/x", "folder")

      assert {:ok, _file, "move conflict"} = Files.read(agent_uid, "from/x")
      assert {:ok, _file, "move conflict"} = Files.read(agent_uid, "target")
      assert {:ok, _file, "move conflict"} = Files.read(agent_uid, "folder/child")
    end

    test "refuses to replace an existing file", %{agent_uid: agent_uid} do
      {:ok, %{sha256: moved}} = Files.store("moved")
      {:ok, %{sha256: kept}} = Files.store("kept")

      {:ok, _files} =
        Files.commit(agent_uid, [
          %{path: "from/x.md", sha256: moved, source: "agent"},
          %{path: "to/x.md", sha256: kept, source: "agent"}
        ])

      assert {:error, :already_exists} = Files.move(agent_uid, "from", "to")
      assert {:ok, _file, "moved"} = Files.read(agent_uid, "from/x.md")

      assert {:ok, _file, "kept"} = Files.read(agent_uid, "to/x.md")
    end
  end

  describe "content paths" do
    test "derive a stable path from the folder, digest, and file name" do
      sha256 = String.duplicate("0123456789abcdef", 4)

      assert Files.content_path("inbox", sha256, "Q3 report.pdf") ==
               "inbox/0123456789abcdef/Q3 report.pdf"

      assert Files.content_path("sent", sha256, "../../etc/passwd") ==
               "sent/0123456789abcdef/.._.._etc_passwd"

      assert Files.content_path("generated", sha256, "") == "generated/0123456789abcdef/file"
    end
  end

  test "a paginated folder carries the same complete revision until its contents or mode change",
       %{agent_uid: uid} do
    {:ok, %{sha256: sha256}} = Files.store("snapshot #{uid}")

    {:ok, _} =
      Files.commit(uid, [
        %{path: "script/a.ts", sha256: sha256, source: "agent"},
        %{path: "script/b.ts", sha256: sha256, source: "agent"}
      ])

    assert {:ok, %{revision: revision, next_after: after_path}} =
             Files.list(uid, "script", limit: 1, snapshot: true)

    assert {:ok, %{revision: ^revision, next_after: nil}} =
             Files.list(uid, "script", limit: 1, after: after_path, snapshot: true)

    {:ok, _} = Files.commit(uid, [%{path: "other.txt", sha256: sha256, source: "agent"}])
    assert {:ok, %{revision: ^revision}} = Files.list(uid, "script", snapshot: true)

    {:ok, _} =
      Files.commit(uid, [%{path: "script/b.ts", sha256: sha256, source: "agent", mode: 0o755}])

    assert {:ok, %{revision: changed}} = Files.list(uid, "script", snapshot: true)
    assert changed != revision
  end

  describe "collection" do
    test "pending attachments survive deletion of their last drive path until delivery", %{
      agent_uid: uid
    } do
      {:ok, %{sha256: sha256}} = Files.store("pending attachment #{uid}")
      {:ok, _} = Files.commit(uid, [%{path: "report.txt", sha256: sha256, source: "agent"}])

      attrs = %{
        agent_uid: uid,
        binding_name: "test",
        outbound_key: "attachment",
        operation: :post,
        payload: %{"attachments" => [%{"blob_ref" => sha256, "name" => "report.txt"}]}
      }

      assert {:ok, intent} = Ankole.Conversations.Delivery.commit(attrs)
      {:ok, _} = Files.commit(uid, [], ["report.txt"])
      digest = Base.decode16!(sha256, case: :lower)

      Repo.update_all(where(Blob, sha256: ^digest),
        set: [last_referenced_at: DateTime.add(DateTime.utc_now(), -2, :day)]
      )

      assert {:ok, 0} = CollectUnreferenced.mark_unreferenced()
      Repo.update_all(where(Blob, sha256: ^digest), set: [deleting: true])
      assert CollectUnreferenced.remove_marked(0) == 0

      assert {:ok, _content} =
               Ankole.Conversations.Delivery.attachment_content(hd(intent.payload["attachments"]))

      intent
      |> Ankole.Conversations.Delivery.Intent.changeset(%{status: :sent})
      |> Repo.update!()

      assert {:ok, 1} = CollectUnreferenced.mark_unreferenced()
      assert CollectUnreferenced.remove_marked(0) == 1
      # Recommitting a completed idempotency key does not require the old bytes.
      assert {:ok, %{status: :sent}} = Ankole.Conversations.Delivery.commit(attrs)
    end

    test "shared external attachments keep their bytes after the receiving Agent is deleted", %{
      agent_uid: uid
    } do
      now = DateTime.utc_now(:microsecond)
      {:ok, %{sha256: sha256}} = Files.store("shared attachment #{uid}")

      {:ok, c} =
        Repo.transact(fn repo ->
          Ankole.Conversations.External.observe_conversation_in_tx(
            repo,
            %{agent_uid: uid},
            %{
              provider_conversation_id: "mock:#{uid}",
              external_kind: :im_group,
              title: "Shared",
              reply_mode: :channel
            },
            now
          )
        end)

      {:ok, %{message: message}} =
        Repo.transact(fn repo ->
          Ankole.Conversations.External.observe_in_tx(
            repo,
            c.id,
            %{
              agent_uid: uid,
              provider_message_id: "file",
              attachments: [%{"name" => "report.txt", "blob_ref" => sha256}]
            },
            now
          )
        end)

      Repo.delete_all(where(AgentFile, agent_uid: ^uid))
      Repo.delete!(Repo.get!(Ankole.Principals.Principal, uid))
      assert Repo.get_by!(Ankole.Conversations.Message, id: message.id).attachments != []
      digest = Base.decode16!(sha256, case: :lower)

      Repo.update_all(where(Blob, sha256: ^digest),
        set: [last_referenced_at: DateTime.add(now, -2, :day)]
      )

      assert {:ok, 0} = CollectUnreferenced.mark_unreferenced()
      Repo.update_all(where(Blob, sha256: ^digest), set: [deleting: true])
      assert CollectUnreferenced.remove_marked(0) == 0
      assert {:ok, "shared attachment " <> ^uid} = ObjectStore.read(Files.object_key(digest))
    end

    test "an attachment cannot adopt bytes that collection has already claimed", %{agent_uid: uid} do
      {:ok, %{sha256: sha256}} = Files.store("collected attachment #{uid}")
      digest = Base.decode16!(sha256, case: :lower)
      Repo.update_all(where(Blob, sha256: ^digest), set: [deleting: true])

      assert {:error, {:blob_missing, ^sha256}} =
               Ankole.Conversations.Delivery.commit(%{
                 agent_uid: uid,
                 binding_name: "test",
                 outbound_key: "missing",
                 operation: :post,
                 payload: %{"attachments" => [%{"blob_ref" => sha256}]}
               })

      refute Repo.exists?(
               from intent in Ankole.Conversations.Delivery.Intent,
                 where: intent.agent_uid == ^uid and intent.outbound_key == "missing"
             )
    end

    test "removes only old unreferenced contents", %{agent_uid: agent_uid} do
      {:ok, %{sha256: kept}} = Files.store("named")
      {:ok, %{sha256: young}} = Files.store("young")
      {:ok, %{sha256: old}} = Files.store("old")
      {:ok, _} = Files.commit(agent_uid, [%{path: "kept.txt", sha256: kept, source: "agent"}])

      old_time = DateTime.add(DateTime.utc_now(), -2, :day)

      for sha256 <- [kept, old] do
        digest = Base.decode16!(sha256, case: :lower)
        Repo.update_all(where(Blob, sha256: ^digest), set: [last_referenced_at: old_time])
      end

      assert {:ok, 1} = CollectUnreferenced.mark_unreferenced()
      assert CollectUnreferenced.remove_marked(0) == 1

      old_digest = Base.decode16!(old, case: :lower)
      assert Repo.get(Blob, old_digest) == nil
      assert {:error, %{"code" => "not_found"}} = ObjectStore.read(Files.object_key(old_digest))

      assert Repo.get(Blob, Base.decode16!(kept, case: :lower))
      assert Repo.get(Blob, Base.decode16!(young, case: :lower))
    end

    test "leaves a marked row that is still referenced", %{agent_uid: agent_uid} do
      {:ok, %{sha256: sha256}} = Files.store("referenced")
      {:ok, _} = Files.commit(agent_uid, [%{path: "a.txt", sha256: sha256, source: "agent"}])
      digest = Base.decode16!(sha256, case: :lower)
      Repo.update_all(where(Blob, sha256: ^digest), set: [deleting: true])

      assert CollectUnreferenced.remove_marked(0) == 0
      assert %Blob{deleting: false} = Repo.get(Blob, digest)
      assert {:ok, _file, "referenced"} = Files.read(agent_uid, "a.txt")
    end
  end
end
