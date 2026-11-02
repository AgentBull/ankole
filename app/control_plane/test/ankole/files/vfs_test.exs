defmodule Ankole.Files.VfsTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  import Plug.Conn
  alias Ankole.Files.Vfs.Auth
  alias Ankole.Files.Nodes
  alias AnkoleWeb.Plugs.VfsWebdav

  defmodule SlowDAV do
    def init(opts), do: opts

    def call(conn, _opts) do
      if conn.method == "GET" && String.ends_with?(conn.request_path, "/slow-read.txt"),
        do: Process.sleep(10_000)

      AnkoleWeb.Plugs.VfsWebdav.call(conn, [])
    end
  end

  defmodule HeadersDAV do
    def init(owner), do: owner

    def call(conn, owner) do
      send(owner, :dav_headers_received)
      send(owner, {:dav_request, conn.method, conn.request_path})
      AnkoleWeb.Plugs.VfsWebdav.call(conn, [])
    end
  end

  setup do
    %{principal: human} = human_fixture()
    %{principal: agent} = agent_fixture(%{owner_principal_uid: human.uid})
    route = "vfs-" <> Ecto.UUID.generate()
    {:ok, worker} = Ankole.SessionsCase.admit_worker(route, %{worker_id: agent.uid})
    {:ok, grant} = Auth.issue(agent.uid, nil)
    %{agent: agent, human: human, actor: actor_fixture(agent), grant: grant, worker: worker}
  end

  test "WebDAV writes exact names, ranges bytes and replaces a file without changing its identity",
       ctx do
    assert request(ctx, "MKCOL", "AgentDrive/empty").status == 201
    assert request(ctx, "MKCOL", "AgentDrive/empty").status == 412
    assert request(ctx, "PROPFIND", "AgentDrive/empty", "", [{"depth", "1"}]).status == 207

    put =
      request(ctx, "PUT", "AgentDrive/empty/report.txt", "0123456789", [{"if-none-match", "*"}])

    assert put.status == 201, put.resp_body
    [id] = get_resp_header(put, "x-ankole-node-id")
    get = request(ctx, "GET", "AgentDrive/empty/report.txt", "", [{"range", "bytes=-3"}])
    assert get.status == 206
    assert get.resp_body == "789"
    assert request(ctx, "PUT", "AgentDrive/temp", "replacement").status == 201

    moved =
      request(ctx, "MOVE", "AgentDrive/temp", "", [
        {"destination", "/api/v1/vfs/dav/AgentDrive/empty/report.txt"},
        {"if-match", hd(get_resp_header(put, "etag"))}
      ])

    assert moved.status == 201, moved.resp_body
    assert get_resp_header(moved, "x-ankole-node-id") == [id]
    assert request(ctx, "GET", "AgentDrive/empty/report.txt").resp_body == "replacement"
    assert request(ctx, "GET", "AgentDrive/temp").status == 404

    assert request(ctx, "MOVE", "AgentDrive/empty", "", [
             {"destination", "/api/v1/vfs/dav/AgentDrive/moved"}
           ]).status == 201

    assert request(ctx, "GET", "AgentDrive/moved/report.txt").resp_body == "replacement"
  end

  test "optimistic writes reject stale changes and replay committed requests without overwriting the browser",
       ctx do
    path = "AgentDrive/note.txt"
    headers = [{"x-ankole-request-id", Ecto.UUID.generate()}, {"if-none-match", "*"}]
    put = request(ctx, "PUT", path, "first", headers)
    assert put.status == 201, put.resp_body
    [id] = get_resp_header(put, "x-ankole-node-id")
    [etag] = get_resp_header(put, "etag")
    replay = request(ctx, "PUT", path, "first", headers)
    assert replay.status == 201, replay.resp_body
    assert get_resp_header(replay, "etag") == [etag]
    assert get_resp_header(replay, "x-ankole-refresh-body") == []
    assert {:ok, _} = Ankole.Files.write_node(ctx.actor, id, "browser")
    replay = request(ctx, "PUT", path, "first", headers)
    assert replay.status == 201, replay.resp_body
    assert get_resp_header(replay, "etag") != [etag]
    assert get_resp_header(replay, "x-ankole-refresh-body") == ["1"]
    assert request(ctx, "PUT", path, "stale", [{"if-match", etag}]).status == 412
    assert request(ctx, "GET", path).resp_body == "browser"
    options = request(ctx, "OPTIONS", "")
    refute hd(get_resp_header(options, "allow")) =~ "LOCK"
    assert get_resp_header(options, "dav") == ["1"]
  end

  test "the site limit is advertised on mount and refresh and rejects oversized streaming uploads",
       ctx do
    key = "drive.vfs_max_upload_bytes"
    {:ok, previous} = Ankole.AppConfigure.get_by_key(key)
    on_exit(fn -> Ankole.AppConfigure.put_global_by_key(key, previous) end)
    assert {:ok, _} = Ankole.AppConfigure.put_global_by_key(key, 1024)
    assert get_resp_header(request(ctx, "OPTIONS", ""), "x-ankole-upload-limit") == ["1024"]

    refresh =
      Plug.Test.conn("POST", "/api/v1/vfs/refresh")
      |> put_req_header("authorization", "Bearer " <> ctx.grant.token)
      |> VfsWebdav.call([])

    assert refresh.status == 200, refresh.resp_body
    assert get_resp_header(refresh, "x-ankole-upload-limit") == ["1024"]
    rejected = request(ctx, "PUT", "AgentDrive/too-large.bin", String.duplicate("x", 1025))
    assert rejected.status == 413, rejected.resp_body
    assert request(ctx, "GET", "AgentDrive/too-large.bin").status == 404
    assert request(ctx, "PUT", "AgentDrive/exact.bin", String.duplicate("x", 1024)).status == 201
  end

  test "MOVE consumes ordinary sources and replays its receipt after the source is gone", ctx do
    put = request(ctx, "PUT", "AgentDrive/target.txt", "old")
    [target_id] = get_resp_header(put, "x-ankole-node-id")
    source = request(ctx, "PUT", "AgentDrive/source.txt", "new")
    [source_id] = get_resp_header(source, "x-ankole-node-id")

    headers = [
      {"destination", "/api/v1/vfs/dav/AgentDrive/target.txt"},
      {"if-match", hd(get_resp_header(put, "etag"))},
      {"x-ankole-request-id", Ecto.UUID.generate()}
    ]

    moved = request(ctx, "MOVE", "AgentDrive/source.txt", "", headers)
    assert moved.status == 201, moved.resp_body
    assert get_resp_header(moved, "x-ankole-node-id") == [target_id]
    assert {:ok, source_node} = Nodes.fetch(source_id)
    assert source_node.deleted_at && source_node.purge_started_at
    replay = request(ctx, "MOVE", "AgentDrive/source.txt", "", headers)
    assert replay.status == 201, replay.resp_body
    assert get_resp_header(replay, "etag") == get_resp_header(moved, "etag")
    assert {:ok, _} = Ankole.Files.write_node(ctx.actor, target_id, "browser")
    replay = request(ctx, "MOVE", "AgentDrive/source.txt", "", headers)
    assert replay.status == 201, replay.resp_body
    assert get_resp_header(replay, "x-ankole-refresh-body") == ["1"]
    assert request(ctx, "GET", "AgentDrive/target.txt").resp_body == "browser"
  end

  test "COPY shares the immutable object while keeping independent file identities", ctx do
    source = request(ctx, "PUT", "AgentDrive/source", "0123456789")
    [source_id] = get_resp_header(source, "x-ankole-node-id")

    copy =
      request(ctx, "COPY", "AgentDrive/source", "", [
        {"destination", "/api/v1/vfs/dav/AgentDrive/copy"},
        {"if-none-match", "*"},
        {"x-ankole-request-id", Ecto.UUID.generate()}
      ])

    assert copy.status == 201, copy.resp_body
    [copy_id] = get_resp_header(copy, "x-ankole-node-id")
    refute copy_id == source_id
    assert {:ok, source_node} = Nodes.fetch(source_id)
    assert {:ok, copy_node} = Nodes.fetch(copy_id)
    assert copy_node.object_id == source_node.object_id
    assert get_resp_header(copy, "x-ankole-size") == ["10"]

    assert get_resp_header(copy, "x-ankole-fingerprint") ==
             get_resp_header(source, "x-ankole-fingerprint")

    assert request(ctx, "GET", "AgentDrive/copy", "", [{"range", "bytes=4-6"}]).resp_body == "456"
    assert request(ctx, "PUT", "AgentDrive/copy", "edited").status == 201
    assert request(ctx, "GET", "AgentDrive/source").resp_body == "0123456789"

    assert request(ctx, "PUT", "AgentDrive/source", "a larger source version").status == 201

    stale =
      request(ctx, "COPY", "AgentDrive/source", "", [
        {"destination", "/api/v1/vfs/dav/AgentDrive/copy"},
        {"x-ankole-expected-etag", hd(get_resp_header(source, "etag"))}
      ])

    assert stale.status == 412, stale.resp_body
    assert request(ctx, "GET", "AgentDrive/copy").resp_body == "edited"
  end

  test "knowledge merges separate blocks and properties but rejects competing edits and missing ancestors",
       ctx do
    path = "AgentDrive/merge._awiki.md"

    original =
      "---\nsummary: original\nowner: original\n---\n\nFirst block.\n\nMiddle block.\n\nLast block.\n"

    base = request(ctx, "PUT", path, original)
    assert base.status == 201, base.resp_body
    [etag] = get_resp_header(base, "etag")

    browser =
      original
      |> String.replace("First block.", "Browser block.")
      |> String.replace("owner: original", "owner: browser")

    assert request(ctx, "PUT", path, browser, [{"if-match", etag}]).status == 201

    edited =
      original
      |> String.replace("Last block.", "Worker block.")
      |> String.replace("summary: original", "summary: worker")

    merged = request(ctx, "PUT", path, edited, [{"if-match", etag}])
    assert merged.status == 201, merged.resp_body
    assert get_resp_header(merged, "x-ankole-refresh-body") == ["1"]
    body = request(ctx, "GET", path).resp_body

    for text <- [
          "Browser block.",
          "Middle block.",
          "Worker block.",
          "owner: browser",
          "summary: worker"
        ],
        do: assert(body =~ text)

    assert request(
             ctx,
             "PUT",
             path,
             String.replace(original, "First block.", "Competing block."),
             [{"if-match", etag}]
           ).status == 412

    assert request(
             ctx,
             "PUT",
             path,
             String.replace(original, "owner: original", "owner: worker"),
             [{"if-match", etag}]
           ).status == 412

    [id] = get_resp_header(base, "x-ankole-node-id")

    assert request(ctx, "PUT", path, edited, [{"if-match", "\"page:#{id}:rev:-1\""}]).status ==
             412

    assert request(ctx, "GET", path).resp_body == body
  end

  test "structured MOVE preserves the source page and subtree, and one restore recovers a deleted tree",
       ctx do
    source = request(ctx, "PUT", "AgentDrive/source._awiki.md", "Source page")
    target = request(ctx, "PUT", "AgentDrive/target._awiki.md", "Target page")
    [source_id] = get_resp_header(source, "x-ankole-node-id")
    [target_id] = get_resp_header(target, "x-ankole-node-id")
    assert request(ctx, "PUT", "AgentDrive/source._asub/child.txt", "Child").status == 201

    moved =
      request(ctx, "MOVE", "AgentDrive/source._awiki.md", "", [
        {"destination", "/api/v1/vfs/dav/AgentDrive/target._awiki.md"},
        {"if-match", hd(get_resp_header(target, "etag"))}
      ])

    assert moved.status == 201, moved.resp_body
    assert get_resp_header(moved, "x-ankole-node-id") == [source_id]
    assert {:ok, %{deleted_at: deleted_at, purge_started_at: nil}} = Nodes.fetch(target_id)
    assert deleted_at
    assert request(ctx, "GET", "AgentDrive/target._asub/child.txt").resp_body == "Child"
    folder = request(ctx, "MKCOL", "AgentDrive/project")
    [folder_id] = get_resp_header(folder, "x-ankole-node-id")

    assert request(ctx, "MOVE", "AgentDrive/target._awiki.md", "", [
             {"destination", "/api/v1/vfs/dav/AgentDrive/project/page._awiki.md"}
           ]).status == 201

    for path <- [
          "AgentDrive/project/page._asub/child.txt",
          "AgentDrive/project/page._awiki.md",
          "AgentDrive/project"
        ] do
      deleted = request(ctx, "DELETE", path)
      assert deleted.status == 204, deleted.resp_body
    end

    assert {:ok, _} = Nodes.restore(ctx.actor, folder_id)
    assert request(ctx, "GET", "AgentDrive/project/page._asub/child.txt").resp_body == "Child"
    assert request(ctx, "GET", "AgentDrive/project/page._awiki.md").resp_body =~ "Source page"
    assert {:ok, %{deleted_at: nil}} = Ankole.Brain.Objects.get_by_slug(source_id)
  end

  test "an editor can delete ordinary files and folders while page deletion requires manage",
       ctx do
    {:ok, root} = Nodes.private_root(ctx.human.uid)
    human_actor = actor_fixture(ctx.human)

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.human, root.id, %{
        grants: [%{principal_uid: ctx.agent.uid, role: "edit"}]
      })

    {:ok, _} = Nodes.create(human_actor, %{parent_id: root.id, kind: :file, name: "file.txt"})
    {:ok, _} = Nodes.create(human_actor, %{parent_id: root.id, kind: :folder, name: "folder"})

    {:ok, _} =
      Ankole.Pod.Pages.create(human_actor, %{
        parent_id: root.id,
        type: :knowledge,
        title: "Protected",
        xml: "<page><p>Keep</p></page>"
      })

    Ankole.ConversationsFixtures.grant_chat(ctx.human.uid, ctx.agent.uid)
    ctx = %{ctx | grant: conversation_grant(ctx)}
    assert request(ctx, "DELETE", "MyDrive/file.txt").status == 204
    assert request(ctx, "DELETE", "MyDrive/folder").status == 204
    assert request(ctx, "DELETE", "MyDrive/Protected._awiki.md").status == 403
    assert request(ctx, "GET", "MyDrive/Protected._awiki.md").resp_body =~ "Keep"
  end

  test "conversation members edit, atomically save, rename and delete shared ChatDrive files",
       ctx do
    Ankole.ConversationsFixtures.grant_chat(ctx.human.uid, ctx.agent.uid)
    grant = conversation_grant(ctx)
    ctx = %{ctx | grant: grant}
    created = request(ctx, "MKCOL", "ChatDrive/reports")
    assert created.status == 201, created.resp_body
    put = request(ctx, "PUT", "ChatDrive/reports/report.txt", "Conversation report")
    assert put.status == 201, put.resp_body
    assert get_resp_header(put, "content-type") == ["text/plain"]
    assert request(ctx, "GET", "ChatDrive/reports/report.txt").resp_body == "Conversation report"
    [id] = get_resp_header(put, "x-ankole-node-id")
    assert Nodes.conversation_id(id) == {:ok, grant.conversation_id}

    assert {:ok, _} = Ankole.Files.write_node(actor_fixture(ctx.human), id, "Human edit")
    current = request(ctx, "GET", "ChatDrive/reports/report.txt")
    assert current.resp_body == "Human edit"
    assert request(ctx, "PUT", "ChatDrive/reports/draft.tmp", "Final report").status == 201

    saved =
      request(ctx, "MOVE", "ChatDrive/reports/draft.tmp", "", [
        {"destination", "/api/v1/vfs/dav/ChatDrive/reports/report.txt"},
        {"if-match", hd(get_resp_header(current, "etag"))}
      ])

    assert saved.status == 201, saved.resp_body
    assert get_resp_header(saved, "x-ankole-node-id") == [id]
    assert request(ctx, "GET", "ChatDrive/reports/report.txt").resp_body == "Final report"
    assert request(ctx, "GET", "ChatDrive/reports/draft.tmp").status == 404

    stranger = human_fixture().principal
    assert {:error, :forbidden} = Ankole.Files.write_node(actor_fixture(stranger), id, "Denied")
    assert {:error, :forbidden} = Nodes.authorize(ctx.actor, id, "node_manage")

    moved =
      request(ctx, "MOVE", "ChatDrive/reports", "", [
        {"destination", "/api/v1/vfs/dav/ChatDrive/archive"}
      ])

    assert moved.status == 201, moved.resp_body
    assert request(ctx, "GET", "ChatDrive/archive/report.txt").resp_body == "Final report"
    assert request(ctx, "DELETE", "ChatDrive/archive/report.txt").status == 204
    assert request(ctx, "DELETE", "ChatDrive/archive").status == 204
  end

  test "knowledge replacement preserves the page and children, reports invalid Markdown immediately",
       ctx do
    put =
      request(
        ctx,
        "PUT",
        "AgentDrive/guide._awiki.md",
        "---\nsummary: hello\n---\n\n# Guide\n\noriginal"
      )

    assert put.status == 201, put.resp_body
    [id] = get_resp_header(put, "x-ankole-node-id")
    assert request(ctx, "PROPFIND", "AgentDrive/guide._asub", "", [{"depth", "0"}]).status == 207
    assert request(ctx, "PUT", "AgentDrive/guide._asub/script.py", "print(1)").status == 201
    get = request(ctx, "GET", "AgentDrive/guide._awiki.md")
    assert get.status == 200
    assert get.resp_body =~ "summary: hello"

    assert request(
             ctx,
             "PUT",
             "AgentDrive/temporary",
             String.replace(get.resp_body, "original", "edited")
           ).status == 201

    move =
      request(ctx, "MOVE", "AgentDrive/temporary", "", [
        {"destination", "/api/v1/vfs/dav/AgentDrive/guide._awiki.md"},
        {"if-match", hd(get_resp_header(get, "etag"))}
      ])

    assert move.status == 201, move.resp_body
    assert get_resp_header(move, "x-ankole-node-id") == [id]
    assert request(ctx, "GET", "AgentDrive/guide._asub/script.py").resp_body == "print(1)"
    assert request(ctx, "GET", "AgentDrive/guide._awiki.md").resp_body =~ "edited"

    assert request(ctx, "PUT", "AgentDrive/guide._awiki.md", "---\nbroken: [\n---\n").status ==
             422

    assert {:ok, node} = Nodes.fetch(id)
    assert node.kind == :knowledge
  end

  test "expected ETags reject mixing revisions in ranged reads", ctx do
    put = request(ctx, "PUT", "AgentDrive/file", "abcdef")
    [etag] = get_resp_header(put, "etag")
    assert request(ctx, "PUT", "AgentDrive/file", "uvwxyz").status == 201

    assert request(ctx, "GET", "AgentDrive/file", "", [
             {"range", "bytes=3-"},
             {"x-ankole-expected-etag", etag}
           ]).status == 412
  end

  test "a rejected streamed body leaves the HTTP connection usable for the next request", ctx do
    key = "drive.vfs_max_upload_bytes"
    {:ok, previous} = Ankole.AppConfigure.get_by_key(key)
    on_exit(fn -> Ankole.AppConfigure.put_global_by_key(key, previous) end)
    assert {:ok, _} = Ankole.AppConfigure.put_global_by_key(key, 1024)
    assert request(ctx, "PUT", "AgentDrive/readable.txt", "next request").status == 201
    server = start_supervised!({Bandit, plug: {HeadersDAV, self()}, port: 0})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    for {method, path, body, status} <- [
          {"PUT", "AgentDrive/invalid._awiki.md", "---\nbroken: [\n---\n", 422},
          {"PUT", "AgentDrive/large.bin", String.duplicate("x", 4096), 413},
          {"PROPFIND", "AgentDrive", "<invalid", 422}
        ] do
      assert {:ok, http} = Mint.HTTP.connect(:http, "localhost", port, mode: :passive)

      headers = [
        {"authorization", "Bearer " <> ctx.grant.token},
        {"content-length", "#{byte_size(body)}"},
        {"depth", "1"}
      ]

      assert {:ok, http, ref} =
               Mint.HTTP.request(http, method, "/api/v1/vfs/dav/" <> path, headers, :stream)

      assert_receive :dav_headers_received, 10_000
      assert {:ok, http} = Mint.HTTP.stream_request_body(http, ref, body)
      assert {:ok, http} = Mint.HTTP.stream_request_body(http, ref, :eof)
      {http, events} = http_response(http, ref)
      assert {:status, ref, status} in events

      assert {:ok, http, ref} =
               Mint.HTTP.request(
                 http,
                 "GET",
                 "/api/v1/vfs/dav/AgentDrive/readable.txt",
                 [{"authorization", "Bearer " <> ctx.grant.token}],
                 nil
               )

      assert_receive :dav_headers_received, 10_000
      {http, events} = http_response(http, ref)
      assert {:status, ref, 200} in events
      assert for({:data, ^ref, data} <- events, into: "", do: data) == "next request"
      Mint.HTTP.close(http)
    end
  end

  @tag timeout: 180_000
  @tag skip: is_nil(System.get_env("ANKOLE_VFS_FUSE_IMAGE"))
  test "packaged mount2 supports random writes, SQLite, atomic saves and symlinks against real DAV",
       ctx do
    if spec_file = System.get_env("ANKOLE_VFS_OBJECT_STORE_SPEC") do
      previous = Application.fetch_env!(:ankole, Ankole.ObjectStore)
      cached = :persistent_term.get({Ankole.ObjectStore, :store}, nil)
      spec = spec_file |> File.read!() |> Torque.decode!()
      Application.put_env(:ankole, Ankole.ObjectStore, spec: spec)
      :persistent_term.erase({Ankole.ObjectStore, :store})

      on_exit(fn ->
        Application.put_env(:ankole, Ankole.ObjectStore, previous)

        if cached,
          do: :persistent_term.put({Ankole.ObjectStore, :store}, cached),
          else: :persistent_term.erase({Ankole.ObjectStore, :store})
      end)
    end

    {:ok, root} = Nodes.private_root(ctx.agent.uid)

    {:ok, _} =
      Ankole.Pod.Pages.create(ctx.actor, %{parent_id: root.id, title: "FuseBase", type: "base"})

    server = start_supervised!({Bandit, plug: {HeadersDAV, self()}, port: 0, ip: {0, 0, 0, 0}})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    directory = Path.join(System.tmp_dir!(), "ankole-fuse-" <> Ecto.UUID.generate())
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf(directory) end)

    config =
      "[test]\ntype = webdav\nvendor = ankole\nurl = http://host.docker.internal:#{port}/api/v1/vfs/dav\nbearer_token = #{ctx.grant.token}\n"

    File.write!(Path.join(directory, "rclone.conf"), config)
    File.chmod!(Path.join(directory, "rclone.conf"), 0o600)
    root = Path.expand("../..", File.cwd!())
    image = System.fetch_env!("ANKOLE_VFS_FUSE_IMAGE")

    {output, status} =
      System.cmd(
        "docker",
        [
          "run",
          "--rm",
          "--device",
          "/dev/fuse",
          "--cap-add",
          "SYS_ADMIN",
          "--security-opt",
          "apparmor=unconfined",
          "--entrypoint",
          "bash",
          fuse_binary_args(),
          "-v",
          directory <> ":/test-config:ro",
          "-v",
          root <> ":/source:ro",
          image,
          "/source/app/agent_computer/test/integration/worker-image/drive-fuse-smoke.sh"
        ]
        |> List.flatten(),
        stderr_to_stdout: true
      )

    assert status == 0, output
    requests = dav_requests([])
    refute {"GET", "/api/v1/vfs/dav/AgentDrive/fuse/large.bin"} in requests

    assert Enum.count(requests, &(&1 == {"COPY", "/api/v1/vfs/dav/AgentDrive/fuse/large.bin"})) ==
             1

    assert Enum.count(
             requests,
             &(&1 == {"PUT", "/api/v1/vfs/dav/AgentDrive/fuse/large-copy.bin"})
           ) == 1

    assert Enum.count(requests, &(&1 == {"PUT", "/api/v1/vfs/dav/AgentDrive/fuse/unchanged.bin"})) ==
             1

    refute Enum.any?(requests, fn {method, _} -> method in ["LOCK", "UNLOCK"] end)

    assert request(ctx, "GET", "AgentDrive/fuse/random.bin").resp_body == "01XYZ56789"
    assert request(ctx, "GET", "AgentDrive/fuse/guide._awiki.md").resp_body =~ "edited"
    assert request(ctx, "GET", "AgentDrive/fuse/link.rclonelink").resp_body == "random.bin"
    assert request(ctx, "GET", "AgentDrive/fuse/after/held.txt").resp_body == "before-after"
    assert request(ctx, "GET", "AgentDrive/fuse/sed-business").resp_body == "must upload"

    for noise <- [".DS_Store", ".note.swp", ".note.swo", ".~lock.report#", "cache.sqlite-shm"] do
      assert request(ctx, "GET", "AgentDrive/fuse/" <> URI.encode(noise)).status == 404
    end
  end

  test "Base paths stream exact exports and replay imports and disjoint field patches", ctx do
    alias Ankole.Pod.{Pages, Bases}
    {:ok, root} = Nodes.private_root(ctx.agent.uid)
    {:ok, page} = Pages.create(ctx.actor, %{parent_id: root.id, title: "Sales", type: "base"})
    {:ok, %{tables: [table]}} = Bases.list_tables(ctx.actor, page.id)
    {:ok, notes} = Bases.create_field(ctx.actor, table.id, %{name: "Notes", type: "text"})

    {:ok, serial} =
      Bases.create_field(ctx.actor, table.id, %{name: "Serial", type: "auto_number"})

    prefix = "AgentDrive/Sales._abase/#{table.name}"

    headers = [
      {"x-ankole-request-id", Ecto.UUID.generate()},
      {"x-ankole-request-ts-ms", "1793577600000"}
    ]

    input =
      "Name,Notes\n\"first, multiline\",\"line one\nline two\"\n" <>
        Enum.map_join(2..205, "", &"row#{&1},note#{&1}\n")

    first = request(ctx, "PUT", prefix <> "/.import/append.csv", input, headers)
    assert first.status == 201, first.resp_body
    assert request(ctx, "PUT", prefix <> "/.import/append.csv", input, headers).status == 201
    assert request(ctx, "GET", prefix <> "/.import/append.csv").resp_body == ""
    assert request(ctx, "GET", prefix <> "/.info/count").resp_body == "205\n"
    {:ok, rows} = Bases.query(ctx.actor, table.id, %{page_size: 205})
    assert Enum.map(rows.records, & &1["data"][serial.id]) == Enum.to_list(1..205)
    assert hd(rows.records)["data"][notes.id] == "line one\nline two"
    listing = request(ctx, "PROPFIND", prefix <> "/.export", "", [{"depth", "1"}])
    assert listing.status == 207, listing.resp_body
    assert listing.resp_body =~ "stat-on-lookup"
    exported = request(ctx, "GET", prefix <> "/.last/3/.columns/Name/.export/json")
    assert exported.status == 200, exported.resp_body

    assert Torque.decode!(exported.resp_body) == [
             %{"Name" => "row203"},
             %{"Name" => "row204"},
             %{"Name" => "row205"}
           ]

    ranged =
      request(ctx, "GET", prefix <> "/.last/3/.columns/Name/.export/json", "", [
        {"range", "bytes=-3"}
      ])

    assert ranged.status == 206
    assert ranged.resp_body == String.slice(exported.resp_body, -3, 3)
    last = List.last(rows.records)
    path = prefix <> "/rec_#{last["id"]}.json"
    original = request(ctx, "GET", path).resp_body |> Torque.decode!()

    {:ok, _} =
      Bases.write_records(ctx.actor, table.id, %{
        updates: [
          %{
            id: last["id"],
            data: %{notes.id => "browser"},
            expected_versions: %{notes.id => last["versions"][notes.id]}
          }
        ]
      })

    body = Torque.encode!(%{base: original, next: Map.put(original, "Name", "edited")})
    patch_headers = [{"x-ankole-record-patch", "1"} | headers]
    patched = request(ctx, "PUT", path, body, patch_headers)
    assert patched.status == 201, patched.resp_body
    after_first = request(ctx, "GET", path).resp_body |> Torque.decode!()
    assert after_first["Name"] == "edited"
    assert after_first["Notes"] == "browser"
    replay = request(ctx, "PUT", path, body, patch_headers)
    assert replay.status == 201, replay.resp_body
    assert request(ctx, "GET", path).resp_body |> Torque.decode!() == after_first
    assert request(ctx, "PUT", prefix <> "/forbidden.rclonelink", "/tmp/outside").status == 403

    assert request(ctx, "MOVE", prefix <> "/.info/schema.json", "", [
             {"destination", "/api/v1/vfs/dav/AgentDrive/stolen.json"}
           ]).status == 403

    {:ok, empty} = Bases.create_field(ctx.actor, table.id, %{name: "Empty", type: "text"})
    before_empty = request(ctx, "GET", path).resp_body |> Torque.decode!()
    assert is_nil(before_empty["_versions"][empty.name])

    body =
      Torque.encode!(%{base: before_empty, next: Map.put(before_empty, empty.name, "filled")})

    assert request(ctx, "PUT", path, body, patch_headers).status == 201
    assert request(ctx, "PUT", path, body, patch_headers).status == 201

    assert request(ctx, "GET", path).resp_body
           |> Torque.decode!()
           |> get_in(["_versions", empty.name]) == 1
  end

  test "Base views project visible columns and preserve fields whose names collide with metadata",
       ctx do
    alias Ankole.Pod.{Pages, Bases}
    {:ok, root} = Nodes.private_root(ctx.agent.uid)
    {:ok, page} = Pages.create(ctx.actor, %{parent_id: root.id, title: "Fields", type: "base"})
    {:ok, %{tables: [table]}} = Bases.list_tables(ctx.actor, page.id)
    {:ok, metadata} = Bases.create_field(ctx.actor, table.id, %{name: "_id", type: "text"})
    {:ok, slashed} = Bases.create_field(ctx.actor, table.id, %{name: "A/B,C", type: "text"})

    {:ok, _} =
      Bases.create_view(ctx.actor, table.id, %{
        name: "Metadata",
        type: "grid",
        config: %{"visible_fields" => [metadata.id]}
      })

    prefix = "AgentDrive/Fields._abase/#{table.name}"

    headers = [
      {"x-ankole-request-id", Ecto.UUID.generate()},
      {"x-ankole-request-ts-ms", "1793577600000"}
    ]

    data = %{"Name" => "Visible", metadata.id => "Business ID", slashed.name => "a/b"}

    assert request(ctx, "PUT", prefix <> "/new_test.json", Torque.encode!(data), headers).status ==
             201

    {:ok, %{records: [row]}} = Bases.query(ctx.actor, table.id, %{})

    record =
      request(ctx, "GET", prefix <> "/.views/Metadata/rec_#{row["id"]}.json").resp_body
      |> Torque.decode!()

    assert record["_id"] == row["id"]
    assert record[metadata.id] == "Business ID"
    refute Map.has_key?(record, slashed.name)
    exported = request(ctx, "GET", prefix <> "/.views/Metadata/.export/json")
    assert Torque.decode!(exported.resp_body) == [Map.take(data, ["Name", metadata.id])]

    filtered =
      request(
        ctx,
        "GET",
        prefix <> "/.filter/#{slashed.id}/a%252Fb/.columns/#{slashed.id}/.export/json"
      )

    assert filtered.status == 200, filtered.resp_body
    assert Torque.decode!(filtered.resp_body) == [%{slashed.name => "a/b"}]
  end

  @tag timeout: 1_800_000
  @tag sandbox: is_nil(System.get_env("ANKOLE_VFS_STRESS"))
  @tag skip: is_nil(System.get_env("ANKOLE_VFS_FUSE_IMAGE"))
  test "the real Worker mount manager shares hot roots and isolates conversation views", ctx do
    human = ctx.human
    {:ok, root} = Nodes.private_root(ctx.agent.uid)

    assert {:ok, _} =
             Ankole.Pod.PagesFixtures.set_sharing(ctx.agent, root.id, %{
               grants: [%{principal_uid: human.uid, role: "edit"}]
             })

    Ankole.ConversationsFixtures.grant_chat(human.uid, ctx.agent.uid)

    grants = for _ <- 1..2, do: conversation_grant(ctx)

    assert hd(grants).scope == List.last(grants).scope
    assert request(ctx, "PUT", "AgentDrive/slow-read.txt", "slow bytes").status == 201
    server = start_supervised!({Bandit, plug: SlowDAV, port: 0, ip: {0, 0, 0, 0}})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    directory = Path.join(System.tmp_dir!(), "ankole-views-" <> Ecto.UUID.generate())
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf(directory) end)

    configs =
      Enum.map(grants, fn grant ->
        %{
          scope: grant.scope,
          view: grant.view,
          token: grant.token,
          conversationId: grant.conversation_id,
          endpoint: "http://host.docker.internal:#{port}/api/v1/vfs/dav"
        }
      end)

    File.write!(Path.join(directory, "views.json"), Torque.encode!(configs))
    File.chmod!(Path.join(directory, "views.json"), 0o600)
    source = Path.expand("../..", File.cwd!())

    container = "ankole-drive-#{Ecto.UUID.generate()}"
    on_exit(fn -> System.cmd("docker", ["rm", "-f", container], stderr_to_stdout: true) end)

    run = fn ->
      System.cmd(
        "docker",
        [
          "run",
          "--name",
          container,
          "--rm",
          "--device",
          "/dev/fuse",
          "--cap-add",
          "SYS_ADMIN",
          "--security-opt",
          "apparmor=unconfined",
          "--entrypoint",
          "bun",
          fuse_binary_args(),
          if(System.get_env("ANKOLE_VFS_STRESS"), do: ["-e", "ANKOLE_VFS_STRESS=1"], else: []),
          "-v",
          directory <> ":/test-config",
          "-v",
          source <> ":/source:ro",
          System.fetch_env!("ANKOLE_VFS_FUSE_IMAGE"),
          "/source/app/agent_computer/test/integration/worker-image/drive-manager-smoke.ts"
        ]
        |> List.flatten(),
        stderr_to_stdout: true
      )
    end

    {output, status} =
      if System.get_env("ANKOLE_VFS_STRESS") do
        task = Task.async(run)

        assert {:ok, true} =
                 Ankole.E2E.WaitHelpers.wait_until(Ankole.E2E.WaitHelpers.deadline(120_000), fn ->
                   File.exists?(Path.join(directory, "stress-ready"))
                 end)

        human_actor = actor_fixture(human)

        timings =
          for index <- 1..100, action <- [:create, :rename] do
            {elapsed, result} =
              :timer.tc(fn ->
                case action do
                  :create ->
                    Ankole.Pod.Pages.create(human_actor, %{
                      parent_id: root.id,
                      title: "browser-#{index}",
                      type: "doc"
                    })

                  :rename ->
                    {:ok, node} = Nodes.child(root.id, "browser-#{index}")

                    Ankole.Pod.Pages.update(human_actor, node.id, %{
                      title: "renamed-#{index}",
                      expected_title: node.name
                    })
                end
              end)

            assert {:ok, _} = result
            elapsed / 1000
          end

        File.write!(Path.join(directory, "stress-done"), "done")
        p99 = timings |> Enum.sort() |> Enum.at(197)

        IO.puts(
          "VFS 20,000-file load, browser create/rename owner p99: #{p99} ms; " <>
            File.read!(Path.join(directory, "stress-ready"))
        )

        assert p99 < 500
        result = Task.await(task, 1_600_000)
        {:ok, folder} = Nodes.child(root.id, "many-small-files")
        assert length(Nodes.list_children(folder.id)) == 20_000
        result
      else
        run.()
      end

    assert status == 0, output
  end

  test "Applet manifests are read-only and expose complete published bytes", ctx do
    {:ok, root} = Nodes.private_root(ctx.agent.uid)

    {:ok, page} =
      Ankole.Pod.Pages.create(ctx.actor, %{parent_id: root.id, title: "App", type: "applet"})

    manifest =
      Enum.map(
        [{"dist/index.html", "<p>Hello</p>"}, {"src/main.tsx", "export default 1"}],
        fn {path, bytes} ->
          {:ok, object} = Ankole.Files.store(bytes)
          source = "publish/#{page.id}/#{path}"

          {:ok, _} =
            Ankole.Files.commit(ctx.agent.uid, [Map.merge(object, %{path: source, source: "pod"})])

          %{path: path, object_id: object.object_id, source_path: source}
        end
      )

    assert {:ok, _} = Ankole.Pod.Files.publish(ctx.actor, page.id, 0, manifest)
    assert request(ctx, "GET", "AgentDrive/App._aapp/dist/index.html").resp_body == "<p>Hello</p>"

    assert request(ctx, "GET", "AgentDrive/App._aapp/src/main.tsx").resp_body ==
             "export default 1"

    assert request(ctx, "PUT", "AgentDrive/App._aapp/src/main.tsx", "partial").status == 403
    assert request(ctx, "DELETE", "AgentDrive/App._aapp/dist/index.html").status == 403
  end

  @tag timeout: 180_000
  @tag skip: is_nil(System.get_env("ANKOLE_VFS_TEST_KUBECONFIG"))
  test "Kubernetes admits the real Worker profile and mounts DAV with the device plugin", ctx do
    alias Ankole.AgentWorkers.{Kubernetes, ProviderKind, WorkerBootstrap}
    alias Ankole.AgentWorkers.Providers.{Configuration, Runtime}
    kube = System.fetch_env!("ANKOLE_VFS_TEST_KUBECONFIG")
    assert String.starts_with?(kubectl!(kube, ["config", "current-context"]), "kind-")
    namespace = "ankole-vfs-#{System.unique_integer([:positive])}"
    kubectl!(kube, ["create", "namespace", namespace])
    on_exit(fn -> kubectl!(kube, ["delete", "namespace", namespace, "--wait=false"]) end)

    kubectl!(kube, [
      "label",
      "namespace",
      namespace,
      "pod-security.kubernetes.io/enforce=privileged"
    ])

    source = Path.expand("../..", File.cwd!())
    directory = Path.join(System.tmp_dir!(), namespace)
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf(directory) end)

    {policy, 0} =
      System.cmd("helm", [
        "template",
        "ankole",
        source <> "/tools/deploy/helm/ankole-agent",
        "--namespace",
        namespace,
        "--show-only",
        "templates/worker-admission.yaml"
      ])

    policy_path = Path.join(directory, "policy.yaml")
    File.write!(policy_path, policy)
    kubectl!(kube, ["apply", "-f", policy_path])
    on_exit(fn -> kubectl!(kube, ["delete", "-f", policy_path, "--ignore-not-found"]) end)
    service_account = "ankole-ankole-agent-worker"
    kubectl!(kube, ["-n", namespace, "create", "serviceaccount", service_account])

    claim = %{
      accessModes: ["ReadWriteOnce"],
      storageClassName: "standard",
      resources: %{requests: %{storage: "128Mi"}}
    }

    config = %{
      namespace: namespace,
      serviceAccount: service_account,
      storage: %{claimTemplate: claim},
      cache: %{sizeLimit: "1Gi"},
      podTemplate: %{spec: %{containers: [%{name: "worker", imagePullPolicy: "Never"}]}},
      stopGraceSeconds: 3
    }

    {:ok, settings} = Configuration.parse(Kubernetes.definition().schema, Torque.encode!(config))

    provider = %Runtime{
      id: Ankole.Ecto.UUIDv7.autogenerate(),
      provider_id: "vfs-test",
      kind: "kubernetes",
      settings: settings,
      secrets: %{},
      settings_digest: Configuration.digest(Kubernetes.definition().schema, settings),
      runtime: %{
        installation: "vfs",
        image: System.fetch_env!("ANKOLE_VFS_FUSE_IMAGE"),
        runtime_fabric_endpoint: "ws://127.0.0.1:1/runtime-fabric/worker"
      }
    }

    spec =
      WorkerBootstrap.agent_worker_spec(provider, ctx.agent.uid, "fuse-test", "test-credential")

    pod =
      Kubernetes.pod_manifest(provider, spec, nil)
      |> update_in(
        ["spec", "containers"],
        &Enum.map(&1, fn container -> Map.put(container, "command", ["sleep", "300"]) end)
      )

    name = pod["metadata"]["name"]

    pvc = %{
      apiVersion: "v1",
      kind: "PersistentVolumeClaim",
      metadata: %{name: ProviderKind.storage_name("vfs", ctx.agent.uid)},
      spec: claim
    }

    manifest = Path.join(directory, "resources.json")

    File.write!(
      manifest,
      Torque.encode!(%{
        apiVersion: "v1",
        kind: "List",
        items: [pvc, Kubernetes.secret_manifest(provider, spec, nil), pod]
      })
    )

    kubectl!(kube, ["-n", namespace, "apply", "-f", manifest])

    kubectl!(kube, [
      "-n",
      namespace,
      "wait",
      "--for=condition=Ready",
      "pod/" <> name,
      "--timeout=60s"
    ])

    bad = pod |> put_in(["metadata", "name"], name <> "-bad") |> put_in(["spec", "hostPID"], true)
    File.write!(manifest, Torque.encode!(bad))

    {denied, status} =
      System.cmd(
        "kubectl",
        ["--kubeconfig", kube, "-n", namespace, "apply", "--dry-run=server", "-f", manifest],
        stderr_to_stdout: true
      )

    assert status != 0 && denied =~ "Worker Pods use their own", denied
    {:ok, root} = Nodes.private_root(ctx.agent.uid)

    {:ok, _} =
      Ankole.Pod.Pages.create(ctx.actor, %{parent_id: root.id, title: "FuseBase", type: "base"})

    server = start_supervised!({Bandit, plug: VfsWebdav, port: 0, ip: {0, 0, 0, 0}})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    File.write!(
      Path.join(directory, "rclone.conf"),
      "[test]\ntype = webdav\nvendor = ankole\nurl = http://host.docker.internal:#{port}/api/v1/vfs/dav\nbearer_token = #{ctx.grant.token}\n"
    )

    kubectl!(kube, ["-n", namespace, "exec", name, "--", "mkdir", "-p", "/test-config"])

    kubectl!(kube, [
      "-n",
      namespace,
      "cp",
      Path.join(directory, "rclone.conf"),
      name <> ":/test-config/rclone.conf"
    ])

    kubectl!(kube, [
      "-n",
      namespace,
      "cp",
      source <> "/app/agent_computer/test/integration/worker-image/drive-fuse-smoke.sh",
      name <> ":/tmp/drive-fuse-smoke.sh"
    ])

    output =
      kubectl!(kube, ["-n", namespace, "exec", name, "--", "bash", "/tmp/drive-fuse-smoke.sh"])

    assert output =~ "FUSE POSIX files, SQLite"
    assert request(ctx, "GET", "AgentDrive/fuse/random.bin").resp_body == "01XYZ56789"
  end

  defp dav_requests(acc) do
    receive do
      {:dav_request, method, path} -> dav_requests([{method, path} | acc])
    after
      0 -> acc
    end
  end

  defp kubectl!(kube, arguments) do
    {output, status} =
      System.cmd("kubectl", ["--kubeconfig", kube | arguments], stderr_to_stdout: true)

    assert status == 0, output
    output
  end

  defp fuse_binary_args do
    case System.get_env("ANKOLE_VFS_FUSE_BINARY") do
      nil -> []
      path -> ["-v", path <> ":/usr/local/bin/ankole-rclone:ro"]
    end
  end

  defp request(ctx, method, path, body \\ "", headers \\ []) do
    Plug.Test.conn(method, "/api/v1/vfs/dav/" <> path, body)
    |> put_req_header("authorization", "Bearer " <> ctx.grant.token)
    |> then(fn conn ->
      Enum.reduce(headers, conn, fn {key, value}, acc -> put_req_header(acc, key, value) end)
    end)
    |> VfsWebdav.call([])
  end

  defp http_response(http, ref, received \\ []) do
    assert {:ok, http, events} = Mint.HTTP.recv(http, 0, 10_000)
    received = received ++ events
    if {:done, ref} in events, do: {http, received}, else: http_response(http, ref, received)
  end

  defp conversation_grant(ctx) do
    id = Ankole.Ecto.UUIDv7.autogenerate()

    {:ok, _} =
      Ankole.ConversationsFixtures.create(ctx.human, %{
        room_mode: :group,
        conversation_id: id,
        agent_uid: ctx.agent.uid,
        message_id: Ankole.Ecto.UUIDv7.autogenerate(),
        text: "Drive view test"
      })

    event = Repo.one!(from s in Ankole.Signals.Signal, where: s.conversation_id == ^id)
    {:ok, grant} = Auth.issue(ctx.agent.uid, %{"signal_id" => event.id})
    grant
  end
end
