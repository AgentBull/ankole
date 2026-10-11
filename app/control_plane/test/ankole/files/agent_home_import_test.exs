defmodule Ankole.Files.AgentHomeImportTest do
  use Ankole.DataCase, async: false

  import ExUnit.CaptureIO
  import Ankole.FilesFixtures
  import Ankole.PrincipalsFixtures

  alias Ankole.AutomationJobs
  alias Ankole.AutomationJobs.Schemas.Job
  alias Ankole.Files
  alias Ankole.Files.AgentHomeImport
  alias Ankole.SignalsGateway

  setup do
    root = Path.join(System.tmp_dir!(), "agent-home-import-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    %{principal: agent} = agent_fixture()
    %{root: root, agent_uid: agent.uid, home: Path.join(root, agent.uid)}
  end

  test "pending legacy attachments migrate their real bytes and retain delivery state", %{
    root: root,
    agent_uid: uid,
    home: home
  } do
    write!(home, "user-files/reports/result.txt", "pre-upgrade result")

    assert {:ok, outbox} =
             Ankole.SignalsGateway.Outbox.commit_outbox(%{
               agent_uid: uid,
               binding_name: "test",
               outbound_key: "legacy-attachment",
               operation: :post,
               status: :unknown_after_send,
               attempt_count: 2,
               payload: %{
                 "attachments" => [
                   %{
                     "agent_computer_path" => "/agents/#{uid}/user-files/reports/result.txt",
                     "user_files_relative_path" => "reports/result.txt",
                     "name" => "result.txt",
                     "mime_type" => "text/plain",
                     "provider_key" => "already-uploaded"
                   }
                 ]
               }
             })

    assert {:ok, %{attachments: 1, skipped: []}} = AgentHomeImport.run(root)

    migrated =
      Repo.get_by!(Ankole.SignalsGateway.OutboxEntry,
        agent_uid: uid,
        outbound_key: outbox.outbound_key,
        binding_name: "test"
      )

    assert migrated.status == :unknown_after_send
    assert migrated.attempt_count == 2
    [attachment] = migrated.payload["attachments"]
    assert attachment["provider_key"] == "already-uploaded"
    refute Map.has_key?(attachment, "agent_computer_path")

    assert {:ok, "pre-upgrade result"} =
             Ankole.SignalsGateway.Outbox.attachment_content(attachment)

    assert {:ok, _file, "pre-upgrade result"} = Files.read(uid, attachment["path"])
    assert {:ok, %{attachments: 0}} = AgentHomeImport.run(root)
  end

  test "repeated attachments retain their order and provider metadata after import", %{
    root: root,
    agent_uid: uid,
    home: home
  } do
    write!(home, "user-files/repeated.txt", "same bytes")

    attachments =
      Enum.map(["first", "second"], fn provider_key ->
        %{
          "user_files_relative_path" => "repeated.txt",
          "name" => "repeated.txt",
          "provider_key" => provider_key
        }
      end)

    assert {:ok, _outbox} =
             Ankole.SignalsGateway.Outbox.commit_outbox(%{
               agent_uid: uid,
               binding_name: "test",
               outbound_key: "repeated-legacy",
               operation: :post,
               payload: %{"attachments" => attachments}
             })

    assert {:ok, %{attachments: 2, skipped: []}} = AgentHomeImport.run(root)

    migrated =
      Repo.get_by!(Ankole.SignalsGateway.OutboxEntry,
        agent_uid: uid,
        binding_name: "test",
        outbound_key: "repeated-legacy"
      )

    [first, second] = migrated.payload["attachments"]
    assert Enum.map([first, second], & &1["provider_key"]) == ["first", "second"]
    assert first["blob_ref"] == second["blob_ref"]
    assert {:ok, "same bytes"} = Ankole.SignalsGateway.Outbox.attachment_content(second)
  end

  test "an unavailable legacy attachment is reported without dropping its intent", %{
    root: root,
    agent_uid: uid,
    home: home
  } do
    File.mkdir_p!(home)

    payload = %{
      "attachments" => [%{"user_files_relative_path" => "missing.txt", "name" => "missing.txt"}]
    }

    assert {:ok, _outbox} =
             Ankole.SignalsGateway.Outbox.commit_outbox(%{
               agent_uid: uid,
               binding_name: "test",
               outbound_key: "missing-legacy",
               operation: :post,
               payload: payload
             })

    assert {:ok, %{attachments: 0, skipped: [_]}} = AgentHomeImport.run(root)

    assert Repo.get_by!(Ankole.SignalsGateway.OutboxEntry,
             agent_uid: uid,
             binding_name: "test",
             outbound_key: "missing-legacy"
           ).payload == payload
  end

  test "a legacy attachment waits for conversion without using a provider attempt", %{
    root: root,
    agent_uid: uid,
    home: home
  } do
    write!(home, "user-files/queued.txt", "queued bytes")

    assert {:ok, _outbox} =
             Ankole.SignalsGateway.Outbox.commit_outbox(%{
               agent_uid: uid,
               binding_name: "test",
               outbound_key: "waiting-legacy",
               operation: :post,
               payload: %{
                 "attachments" => [
                   %{"user_files_relative_path" => "queued.txt", "name" => "queued.txt"}
                 ]
               }
             })

    adapter = %Ankole.SignalsGateway.OutboxAdapter{
      capabilities: MapSet.new([:post_entry]),
      reconcile_fun: nil,
      send_fun: fn _outbox -> flunk("legacy bytes must not reach a provider") end
    }

    assert {:error, :attachment_migration_required} =
             Ankole.SignalsGateway.Outbox.dispatch_outbox(uid, "test", "waiting-legacy", adapter)

    waiting =
      Repo.get_by!(Ankole.SignalsGateway.OutboxEntry,
        agent_uid: uid,
        binding_name: "test",
        outbound_key: "waiting-legacy"
      )

    assert waiting.status == :created
    assert waiting.attempt_count == 0
    assert {:ok, %{attachments: 1}} = AgentHomeImport.run(root)

    assert_enqueued(
      worker: Ankole.SignalsGateway.Jobs.OutboxDispatch,
      args: %{agent_uid: uid, binding_name: "test", outbound_key: "waiting-legacy"}
    )
  end

  test "release and Mix entry points import all tenants without a caller context", %{
    root: root,
    tenant: first,
    agent_uid: first_uid,
    home: first_home
  } do
    second = create_tenant()
    %{principal: second_agent} = Repo.with_tenant(second.id, fn -> agent_fixture() end)
    second_uid = second_agent.uid
    second_home = Path.join(root, second_uid)
    skill_path = "skills/weather/SKILL.md"

    write!(first_home, "installed-skills/weather/SKILL.md", "# First tenant")
    write!(second_home, "installed-skills/weather/SKILL.md", "# Second tenant")
    write!(first_home, "automation/price/main.ts", "console.log('first')\n")
    write!(second_home, "automation/price/main.ts", "console.log('second')\n")
    drive_file_fixture(first_uid, skill_path, "# Existing first tenant")

    first_job = legacy_job!(first_uid, "/agents/#{first_uid}/automation/price")

    second_job =
      Repo.with_tenant(second.id, fn ->
        legacy_job!(second_uid, "/agents/#{second_uid}/automation/price")
      end)

    for {tenant, uid, home} <- [
          {first, first_uid, first_home},
          {second, second_uid, second_home}
        ] do
      write!(home, "user-files/result.txt", "attachment:#{uid}")

      Repo.with_tenant(tenant.id, fn ->
        assert {:ok, _outbox} =
                 Ankole.SignalsGateway.Outbox.commit_outbox(%{
                   agent_uid: uid,
                   binding_name: "test",
                   outbound_key: "tenant-attachment",
                   operation: :post,
                   payload: %{
                     "attachments" => [
                       %{"user_files_relative_path" => "result.txt", "name" => "result.txt"}
                     ]
                   }
                 })
      end)
    end

    output =
      capture_io(fn ->
        Repo.without_tenant(fn ->
          assert Repo.tenant_id() == nil
          assert :ok = Ankole.Release.import_agent_home(root)
          assert Repo.tenant_id() == nil
        end)
      end)

    assert output =~ "Imported 3 files for 2 Agents and 2 Automation Job scripts."
    assert output =~ "Migrated 2 pending outbox attachments."
    assert Repo.tenant_id!() == first.id

    for {tenant, uid, other_uid, job, skill, script} <- [
          {first, first_uid, second_uid, first_job, "# Existing first tenant",
           "console.log('first')\n"},
          {second, second_uid, first_uid, second_job, "# Second tenant",
           "console.log('second')\n"}
        ] do
      Repo.with_tenant(tenant.id, fn ->
        assert {:ok, skill_file, ^skill} = Files.read(uid, skill_path)
        assert {:ok, script_file, ^script} = Files.read(uid, job.drive_prefix <> "/main.ts")
        assert skill_file.tenant_id == tenant.id
        assert script_file.tenant_id == tenant.id
        assert {:error, :not_found} = Files.fetch(other_uid, skill_path)
        assert Repo.get!(Job, job.id).legacy_directory_path == nil

        outbox =
          Repo.get_by!(Ankole.SignalsGateway.OutboxEntry,
            agent_uid: uid,
            binding_name: "test",
            outbound_key: "tenant-attachment"
          )

        [attachment] = outbox.payload["attachments"]
        assert {:ok, file, bytes} = Files.read(uid, attachment["path"])
        assert file.tenant_id == tenant.id
        assert bytes == "attachment:#{uid}"
        assert {:error, :not_found} = Files.fetch(other_uid, attachment["path"])
      end)
    end

    output =
      capture_io(fn ->
        Repo.without_tenant(fn ->
          assert :ok = Mix.Tasks.Ankole.Files.ImportAgentHome.run([root])
          assert Repo.tenant_id() == nil
        end)
      end)

    assert output =~ "Imported 0 files for 2 Agents and 0 Automation Job scripts."
    assert output =~ "Migrated 0 pending outbox attachments."
    assert Repo.tenant_id!() == first.id
  end

  test "copies installed Skills once and keeps user files on persistent storage", %{
    root: root,
    agent_uid: agent_uid,
    home: home
  } do
    write!(home, "user-files/reports/q3.md", "Q3")
    write!(home, "user-files/inbox/41/photo.png", <<137, 80, 78, 71>>)
    write!(home, "installed-skills/weather/SKILL.md", "# Weather")
    write!(home, "installed-skills/weather/scripts/fetch.sh", "#!/bin/sh\n")
    File.chmod!(Path.join(home, "installed-skills/weather/scripts/fetch.sh"), 0o755)
    write!(home, "installed-skills/.ankole/drive-index.json", "{}")
    write!(home, "workspace/scratch.txt", "not a drive file")
    File.ln_s!("/etc/hostname", Path.join(home, "installed-skills/weather/link"))
    write!(Path.join(root, "deleted-agent"), "user-files/private.md", "old owner")
    File.mkdir_p!(Path.join(root, ".deleted"))
    File.mkdir_p!(Path.join(root, "lost+found"))

    drive_file_fixture(agent_uid, "user-files/reports/q3.md", "edited in the drive")

    assert {:ok, report} = AgentHomeImport.run(root)
    assert %{agents: 1, files: 2, jobs: 0, jobs_without_script: []} = report
    assert report.deleted_agent_homes == [Path.join(root, "deleted-agent")]

    assert AgentHomeImport.format_report(report) =~
             "No Agent has the UID of #{Path.join(root, "deleted-agent")}"

    assert [{skipped, {:not_a_regular_file, :symlink}}] = report.skipped
    assert String.ends_with?(skipped, "installed-skills/weather/link")

    assert paths(agent_uid) == [
             "skills/weather/SKILL.md",
             "skills/weather/scripts/fetch.sh",
             "user-files/reports/q3.md"
           ]

    assert File.read!(Path.join(home, "user-files/inbox/41/photo.png")) == <<137, 80, 78, 71>>
    assert File.read!(Path.join(home, "user-files/reports/q3.md")) == "Q3"
    assert {:ok, _file, "edited in the drive"} = Files.read(agent_uid, "user-files/reports/q3.md")
    assert {:ok, %{mode: 0o755}} = Files.fetch(agent_uid, "skills/weather/scripts/fetch.sh")

    assert {:ok, %{files: 0}} = AgentHomeImport.run(root)
  end

  test "copies legacy Automation Job scripts to their drive folders", %{
    root: root,
    agent_uid: agent_uid,
    home: home
  } do
    write!(home, "automation/price/main.ts", "console.log('price')\n")
    write!(home, "automation/price/lib/parse.ts", "export {}\n")
    with_script = legacy_job!(agent_uid, "/agents/#{agent_uid}/automation/price")
    without_script = legacy_job!(agent_uid, "/agents/#{agent_uid}/automation/gone")

    assert {:ok, %{jobs: 1, jobs_without_script: [id]}} = AgentHomeImport.run(root)
    assert id == without_script.id

    prefix = with_script.drive_prefix
    assert paths(agent_uid, prefix) == ["#{prefix}/lib/parse.ts", "#{prefix}/main.ts"]
    assert Repo.get!(Job, with_script.id).legacy_directory_path == nil
    # A script that this run did not find keeps its path for a later run.
    assert Repo.get!(Job, without_script.id).legacy_directory_path ==
             "/agents/#{agent_uid}/automation/gone"
  end

  test "clears the path of a script whose only skipped entry is a symlink", %{
    root: root,
    agent_uid: agent_uid,
    home: home
  } do
    write!(home, "automation/tool/main.ts", "console.log('tool')\n")
    link = Path.join(home, "automation/tool/node_modules/.bin/tool")
    File.mkdir_p!(Path.dirname(link))
    File.ln_s!("../tool/cli.js", link)
    job = legacy_job!(agent_uid, "/agents/#{agent_uid}/automation/tool")

    assert {:ok, %{skipped: [{^link, {:not_a_regular_file, :symlink}}]}} =
             AgentHomeImport.run(root)

    # A symlink is skipped on every run, so it does not keep the job pending.
    assert Repo.get!(Job, job.id).legacy_directory_path == nil
    assert paths(agent_uid, job.drive_prefix) == ["#{job.drive_prefix}/main.ts"]
  end

  test "keeps the path of a script that was not copied completely", %{
    root: root,
    agent_uid: agent_uid,
    home: home
  } do
    write!(home, "automation/report/main.ts", "console.log('report')\n")
    write!(home, "automation/report/secret.ts", "export {}\n")
    unreadable = Path.join(home, "automation/report/secret.ts")
    File.chmod!(unreadable, 0o000)
    on_exit(fn -> File.chmod(unreadable, 0o644) end)
    job = legacy_job!(agent_uid, "/agents/#{agent_uid}/automation/report")

    assert {:ok, %{skipped: [{^unreadable, {:invalid_source, :eacces}}]}} =
             AgentHomeImport.run(root)

    assert Repo.get!(Job, job.id).legacy_directory_path != nil

    File.chmod!(unreadable, 0o644)
    assert {:ok, %{skipped: []}} = AgentHomeImport.run(root)

    assert paths(agent_uid, job.drive_prefix) == [
             "#{job.drive_prefix}/main.ts",
             "#{job.drive_prefix}/secret.ts"
           ]

    assert Repo.get!(Job, job.id).legacy_directory_path == nil
  end

  test "reports an Agent Home that it cannot read instead of taking it for an empty one", %{
    root: root,
    agent_uid: agent_uid,
    home: home
  } do
    write!(home, "user-files/report.md", "kept by a root Worker")
    File.chmod!(home, 0o000)
    on_exit(fn -> File.chmod(home, 0o755) end)

    assert {:ok, %{files: 0, skipped: skipped}} = AgentHomeImport.run(root)
    assert {Path.join(home, "installed-skills"), :eacces} in skipped
    assert paths(agent_uid) == []
  end

  test "leaves Job workspaces and session files on persistent storage", %{
    root: root,
    home: home,
    agent_uid: agent_uid
  } do
    files = [
      "jobs/42/report.md",
      "jobs/42/.ankole/state.json",
      "jobs/42/temp/scratch",
      "sessions/123/notes.md"
    ]

    for path <- files, do: write!(home, path, "original " <> path)

    assert {:ok, %{files: 0}} = AgentHomeImport.run(root)
    assert paths(agent_uid) == []
    for path <- files, do: assert(File.read!(Path.join(home, path)) == "original " <> path)
  end

  test "rejects a root that is not a directory", %{root: root} do
    assert {:error, {:not_a_directory, ^root}} = AgentHomeImport.run(root)
  end

  defp write!(home, relative, content) do
    path = Path.join(home, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  defp paths(agent_uid, prefix \\ "") do
    {:ok, %{files: files}} = Files.list(agent_uid, prefix)
    files |> Enum.map(& &1.path) |> Enum.reject(&String.starts_with?(&1, "automation/scaffold"))
  end

  # A job as the migration left it: an empty drive folder and the old
  # Agent Home directory in `legacy_directory_path`.
  defp legacy_job!(agent_uid, legacy_directory_path) do
    unique = System.unique_integer([:positive])

    {:ok, source} =
      SignalsGateway.append_actor_event(%{
        agent_uid: agent_uid,
        binding_name: "lark",
        session_id: "import-session-#{unique}",
        source_event_id: "import-source-#{unique}",
        signal_channel_id: "lark:chat:#{unique}",
        source_entry_id: "message-#{unique}",
        type: "im.message.addressed",
        available_at: DateTime.utc_now(),
        sender_key: agent_uid,
        payload: %{"text" => "register"}
      })

    scaffold = "automation/scaffold-#{unique}"
    drive_file_fixture(agent_uid, scaffold <> "/main.ts")

    {:ok, job} =
      AutomationJobs.create_job(%{
        agent_uid: agent_uid,
        owner_session_id: source.session_id,
        source_actor_event_id: source.id,
        source_entry_id: source.source_entry_id,
        source_provenance: %{"kind" => "test"},
        reply_route: %{"binding_name" => source.binding_name},
        drive_prefix: scaffold,
        label: "Legacy job #{unique}",
        wake_on_failure: false
      })

    prefix = "automation/#{job.id}"

    Repo.update_all(where(Job, id: ^job.id),
      set: [drive_prefix: prefix, legacy_directory_path: legacy_directory_path]
    )

    %{job | drive_prefix: prefix}
  end
end
