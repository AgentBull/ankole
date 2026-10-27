defmodule Ankole.Upgrade202610Test do
  use Ankole.DataCase, async: false
  import ExUnit.CaptureIO
  import Ankole.FilesFixtures
  import Ankole.PrincipalsFixtures
  alias Ankole.AppConfigure.AppConfig
  alias Ankole.AppConfigure.Crypto
  alias Ankole.AppConfigure.SiteConfig
  alias Ankole.AutomationJobs
  alias Ankole.AutomationJobs.Schemas.Job
  alias Ankole.Files
  alias Ankole.Plugins.Microsoft365Adapter.Config, as: TeamsConfig
  alias Ankole.Plugins.SlackAdapter.Config, as: SlackConfig
  alias Ankole.Signals.Binding
  alias Ankole.Signals.Bindings
  alias Ankole.Upgrade202610

  setup do
    Req.Test.set_req_test_to_shared()
    previous = Application.fetch_env(:ankole, SlackConfig)

    Application.put_env(:ankole, SlackConfig,
      client_opts: [req_options: [plug: {Req.Test, __MODULE__}]]
    )

    on_exit(fn ->
      case previous do
        {:ok, config} -> Application.put_env(:ankole, SlackConfig, config)
        :error -> Application.delete_env(:ankole, SlackConfig)
      end
    end)

    Req.Test.stub(__MODULE__, fn conn ->
      refute Repo.in_transaction?(),
             "upgrade identity resolution cannot hold a database transaction"

      case conn.request_path do
        "/api/auth.test" ->
          Req.Test.json(conn, %{"ok" => true, "bot_id" => "BOLD", "user_id" => "UOLD"})

        "/api/bots.info" ->
          Req.Test.json(conn, %{"ok" => true, "bot" => %{"app_id" => "AOLD"}})
      end
    end)

    :ok
  end

  for {adapter, module} <- [{"slack", SlackConfig}, {"teams", TeamsConfig}] do
    @adapter adapter
    @config_module module
    test "#{adapter} shared keys split into independently encrypted Agent rows and repeat without changes" do
      %{principal: first} = agent_fixture()
      %{principal: second} = agent_fixture()
      key = @config_module.chat_config_key("shared")
      {:ok, config} = @config_module.validate_chat_config(config(@adapter))
      old_value = seed_config(key, config)

      for agent <- [first, second] do
        assert {:ok, _} =
                 Ankole.SignalsFixtures.raw_binding_fixture(%{
                   agent_uid: agent.uid,
                   name: "shared",
                   adapter: @adapter,
                   config_ref: "app-config://#{key}"
                 })
      end

      assert :ok = Repo.without_tenant(&Upgrade202610.run/0)
      refute Repo.get_by(SiteConfig, scope: "global", key: key)

      rows =
        for agent <- [first, second] do
          binding = Repo.get_by!(Binding, agent_uid: agent.uid, name: "shared")
          new_key = @config_module.binding_config_key(agent.uid, "shared")
          assert binding.config_ref == "app-config://#{new_key}"
          row = Repo.get_by!(SiteConfig, scope: "global", key: new_key)
          assert row.value["type"] == old_value["type"]
          refute row.value["value"] == old_value["value"]
          assert {:ok, ^config} = Bindings.stored_binding_config(binding)
          assert is_binary(row.value["platform_application"])
          row
        end

      refute hd(rows).value["value"] == List.last(rows).value["value"]

      Req.Test.stub(__MODULE__, fn _ ->
        flunk("resolved rows must not request identity on repeat")
      end)

      assert :ok = Repo.without_tenant(&Upgrade202610.run/0)

      for row <- rows,
          do: assert(Repo.get_by!(SiteConfig, scope: row.scope, key: row.key).value == row.value)
    end
  end

  test "lark legacy signals.lark.bindings.* keys migrate to binding_configs and repeat without changes" do
    alias Ankole.Plugins.LarkAdapter.Config, as: LarkConfig

    %{principal: first} = agent_fixture()
    %{principal: second} = agent_fixture()

    cases = [
      {first, "feishu-main", "signals.lark.bindings.#{first.uid}", "cli_legacy_uid"},
      {second, "feishu-ops", "signals.lark.bindings.feishu-ops", "cli_legacy_name"}
    ]

    seeded =
      for {agent, name, old_key, app_id} <- cases do
        {:ok, cfg} =
          LarkConfig.validate_chat_config(%{
            "appID" => app_id,
            "appSecret" => "secret-#{app_id}",
            "domain" => "feishu"
          })

        old_value = seed_config(old_key, cfg)

        assert {:ok, _} =
                 Ankole.SignalsFixtures.raw_binding_fixture(%{
                   agent_uid: agent.uid,
                   name: name,
                   adapter: "lark",
                   config_ref: "app-config://#{old_key}"
                 })

        {agent, name, old_key, cfg, old_value}
      end

    assert :ok = Repo.without_tenant(&Upgrade202610.run/0)

    rows =
      for {agent, name, old_key, cfg, old_value} <- seeded do
        refute Repo.get_by(SiteConfig, scope: "global", key: old_key)
        binding = Repo.get_by!(Binding, agent_uid: agent.uid, name: name)
        new_key = LarkConfig.binding_config_key(agent.uid, name)
        assert binding.config_ref == "app-config://#{new_key}"

        row = Repo.get_by!(SiteConfig, scope: "global", key: new_key)
        assert row.value["type"] == old_value["type"]
        refute row.value["value"] == old_value["value"]
        assert {:ok, ^cfg} = Bindings.stored_binding_config(binding)
        assert {:ok, application} = LarkConfig.platform_application(cfg)
        assert row.value["platform_application"] == application
        row
      end

    assert :ok = Repo.without_tenant(&Upgrade202610.run/0)

    for row <- rows,
        do: assert(Repo.get_by!(SiteConfig, scope: row.scope, key: row.key).value == row.value)
  end

  for {adapter, module} <- [
        {"line", Ankole.Plugins.LineAdapter.Config},
        {"lark", Ankole.Plugins.LarkAdapter.Config},
        {"email", Ankole.Plugins.EmailAdapter.Config},
        {"whatsapp", Ankole.Plugins.WhatsAppAdapter.Config}
      ] do
    @adapter adapter
    @config_module module
    test "#{adapter} existing binding configs gain an application identity without changing their values" do
      %{principal: agent} = agent_fixture()
      key = @config_module.binding_config_key(agent.uid, "existing")
      {:ok, config} = @config_module.validate_binding_config(config(@adapter))
      seed_config(key, config)

      assert {:ok, binding} =
               Ankole.SignalsFixtures.raw_binding_fixture(%{
                 agent_uid: agent.uid,
                 name: "existing",
                 adapter: @adapter,
                 config_ref: "app-config://#{key}",
                 enabled: true
               })

      assert :ok = Repo.without_tenant(&Upgrade202610.run/0)
      assert {:ok, ^config} = Bindings.binding_config(binding, @config_module)
      assert {:ok, application} = @config_module.platform_application(config)
      row = Repo.get_by!(SiteConfig, scope: "global", key: key)
      assert row.value["platform_application"] == application

      assert :ok = Repo.without_tenant(&Upgrade202610.run/0)
      assert Repo.get_by!(SiteConfig, scope: "global", key: key).value == row.value
    end
  end

  test "a conflicting destination aborts the entire shared-key split without deleting old credentials" do
    %{principal: first} = agent_fixture()
    %{principal: second} = agent_fixture()
    key = TeamsConfig.chat_config_key("shared-conflict")
    {:ok, config} = TeamsConfig.validate_chat_config(config("teams"))
    seed_config(key, config)

    for agent <- [first, second],
        do:
          Ankole.SignalsFixtures.raw_binding_fixture(%{
            agent_uid: agent.uid,
            name: "shared-conflict",
            adapter: "teams",
            config_ref: "app-config://#{key}"
          })

    destination = TeamsConfig.binding_config_key(second.uid, "shared-conflict")
    seed_config(destination, Map.put(config, "appPassword", "different"))

    assert_raise RuntimeError, ~r/binding_configuration_key_conflict/, fn ->
      Repo.without_tenant(&Upgrade202610.run/0)
    end

    assert Repo.get_by(SiteConfig, scope: "global", key: key)

    for agent <- [first, second],
        do:
          assert(
            Repo.get_by!(Binding,
              agent_uid: agent.uid,
              name: "shared-conflict"
            ).config_ref == "app-config://#{key}"
          )

    refute Repo.get_by(SiteConfig,
             scope: "global",
             key: TeamsConfig.binding_config_key(first.uid, "shared-conflict")
           )
  end

  test "identity ciphertext moves only to the original tenant and repeat tolerates its new name",
       %{
         tenant: other
       } do
    original = Repo.get_by!(Ankole.Tenants.Tenant, slug: "default")
    key = "principals.identity_providers.lark.migration-#{Ecto.UUID.generate()}"
    value = %{"appID" => "migration-fixture", "appSecret" => "migration-secret"}
    seed_config(key, value)
    Repo.query!("ALTER TABLE tenants DROP COLUMN base_db_id")

    assert :ok = Repo.without_tenant(&Upgrade202610.run/0)
    scope = "tenant:" <> original.id
    row = Repo.with_tenant(original.id, fn -> Repo.get_by!(AppConfig, scope: scope, key: key) end)
    assert row.tenant_id == original.id
    assert {:ok, ^value} = Crypto.unseal(row.value["value"], scope, key)
    assert {:error, _} = Crypto.unseal(row.value["value"], "global", key)
    refute Repo.get_by(SiteConfig, scope: "global", key: key)

    Repo.with_tenant(other.id, fn ->
      assert :error = Ankole.AppConfigure.get_by_key(key)
    end)

    original
    |> Ecto.Changeset.change(slug: "original-#{Ecto.UUID.generate()}")
    |> Repo.update!()

    assert :ok = Repo.without_tenant(&Upgrade202610.run/0)

    assert Repo.with_tenant(original.id, fn ->
             Repo.get_by!(AppConfig, scope: scope, key: key).value
           end) == row.value

    assert Repo.tenant_id!() == other.id
  end

  describe "import_agent_home/1" do
    setup do
      root =
        Path.join(System.tmp_dir!(), "agent-home-import-#{System.unique_integer([:positive])}")

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

      assert {:ok, intent} =
               Ankole.SignalsFixtures.commit_delivery(%{
                 agent_uid: uid,
                 binding_name: "test",
                 outbound_key: "legacy-attachment",
                 operation: :post,
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

      # Restore the delivery state that existed before the attachment migration.
      intent
      |> AshPostgres.DataLayer.to_ecto()
      |> Ecto.Changeset.change(status: :unknown, attempt_count: 2)
      |> Repo.update!()

      assert %{attachments: 1, skipped: []} = import_home(root)

      migrated =
        Repo.get_by!(Ankole.Conversations.Delivery.Intent,
          agent_uid: uid,
          outbound_key: intent.outbound_key,
          binding_name: "test"
        )

      assert migrated.status == :unknown
      assert migrated.attempt_count == 2
      [attachment] = migrated.payload["attachments"]
      assert attachment["provider_key"] == "already-uploaded"
      refute Map.has_key?(attachment, "agent_computer_path")

      assert {:ok, "pre-upgrade result"} =
               Ankole.Conversations.Delivery.attachment_content(attachment)

      assert {:ok, _file, "pre-upgrade result"} = Files.read(uid, attachment["path"])
      assert %{attachments: 0} = import_home(root)
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

      assert {:ok, _intent} =
               Ankole.SignalsFixtures.commit_delivery(%{
                 agent_uid: uid,
                 binding_name: "test",
                 outbound_key: "repeated-legacy",
                 operation: :post,
                 payload: %{"attachments" => attachments}
               })

      assert %{attachments: 2, skipped: []} = import_home(root)

      migrated =
        Repo.get_by!(Ankole.Conversations.Delivery.Intent,
          agent_uid: uid,
          binding_name: "test",
          outbound_key: "repeated-legacy"
        )

      [first, second] = migrated.payload["attachments"]
      assert Enum.map([first, second], & &1["provider_key"]) == ["first", "second"]
      assert first["blob_ref"] == second["blob_ref"]
      assert {:ok, "same bytes"} = Ankole.Conversations.Delivery.attachment_content(second)
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

      assert {:ok, _intent} =
               Ankole.SignalsFixtures.commit_delivery(%{
                 agent_uid: uid,
                 binding_name: "test",
                 outbound_key: "missing-legacy",
                 operation: :post,
                 payload: payload
               })

      assert %{attachments: 0, skipped: [_]} = import_home(root)

      assert Repo.get_by!(Ankole.Conversations.Delivery.Intent,
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

      assert {:ok, _intent} =
               Ankole.SignalsFixtures.commit_delivery(%{
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

      adapter = %Ankole.Conversations.Delivery.Adapter{
        capabilities: MapSet.new([:post_entry]),
        reconcile_fun: nil,
        deliver_fun: fn _intent -> flunk("legacy bytes must not reach a provider") end
      }

      assert {:error, :attachment_migration_required} =
               Ankole.Conversations.Delivery.dispatch(uid, "test", "waiting-legacy", adapter)

      waiting =
        Repo.get_by!(Ankole.Conversations.Delivery.Intent,
          agent_uid: uid,
          binding_name: "test",
          outbound_key: "waiting-legacy"
        )

      assert waiting.status == :pending
      assert waiting.attempt_count == 0
      assert %{attachments: 1} = import_home(root)

      assert_enqueued(
        worker: Ankole.Conversations.Delivery.Jobs.Dispatch,
        args: %{agent_uid: uid, binding_name: "test", outbound_key: "waiting-legacy"}
      )
    end

    test "imports all tenants without a caller context and restores the caller tenant", %{
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
          assert {:ok, _intent} =
                   Ankole.SignalsFixtures.commit_delivery(%{
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

      {_report, output} =
        with_io(fn ->
          Repo.without_tenant(fn ->
            assert Repo.tenant_id() == nil
            report = Upgrade202610.import_agent_home(root)
            assert Repo.tenant_id() == nil
            report
          end)
        end)

      assert output =~ "Imported 3 files for 2 Agents and 2 Automation Job scripts."
      assert output =~ "Migrated 2 pending intent attachments."
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

          intent =
            Repo.get_by!(Ankole.Conversations.Delivery.Intent,
              agent_uid: uid,
              binding_name: "test",
              outbound_key: "tenant-attachment"
            )

          [attachment] = intent.payload["attachments"]
          assert {:ok, file, bytes} = Files.read(uid, attachment["path"])
          assert file.tenant_id == tenant.id
          assert bytes == "attachment:#{uid}"
          assert {:error, :not_found} = Files.fetch(other_uid, attachment["path"])
        end)
      end

      {_report, output} = with_io(fn -> Upgrade202610.import_agent_home(root) end)

      assert output =~ "Imported 0 files for 2 Agents and 0 Automation Job scripts."
      assert output =~ "Migrated 0 pending intent attachments."
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

      {report, output} = with_io(fn -> Upgrade202610.import_agent_home(root) end)
      assert %{agents: 1, files: 2, jobs: 0, jobs_without_script: []} = report
      assert report.deleted_agent_homes == [Path.join(root, "deleted-agent")]

      assert output =~
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

      assert {:ok, _file, "edited in the drive"} =
               Files.read(agent_uid, "user-files/reports/q3.md")

      assert {:ok, %{mode: 0o755}} = Files.fetch(agent_uid, "skills/weather/scripts/fetch.sh")

      assert %{files: 0} = import_home(root)
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

      assert %{jobs: 1, jobs_without_script: [id]} = import_home(root)
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

      assert %{skipped: [{^link, {:not_a_regular_file, :symlink}}]} = import_home(root)

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

      assert %{skipped: [{^unreadable, {:invalid_source, :eacces}}]} = import_home(root)

      assert Repo.get!(Job, job.id).legacy_directory_path != nil

      File.chmod!(unreadable, 0o644)
      assert %{skipped: []} = import_home(root)

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

      assert %{files: 0, skipped: skipped} = import_home(root)
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

      assert %{files: 0} = import_home(root)
      assert paths(agent_uid) == []
      for path <- files, do: assert(File.read!(Path.join(home, path)) == "original " <> path)
    end

    test "rejects a root that is not a directory", %{root: root} do
      assert_raise RuntimeError, ~r/not_a_directory/, fn ->
        import_home(root)
      end
    end
  end

  defp import_home(root) do
    {report, _output} = with_io(fn -> Upgrade202610.import_agent_home(root) end)
    report
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

    source =
      Ankole.SignalsFixtures.external_session_signal_fixture(agent_uid, binding_name: "lark")

    scaffold = "automation/scaffold-#{unique}"
    drive_file_fixture(agent_uid, scaffold <> "/main.ts")

    {:ok, job} =
      AutomationJobs.create_job(%{
        agent_uid: agent_uid,
        owner_session_id: source.session_id,
        source_signal_id: source.id,
        provider_message_id: source.provider_message_id,
        source_provenance: %{"kind" => "test"},
        reply_route: %{"binding_name" => source.reply_binding_name},
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

  test "site mail settings decrypt with the old key and seal with the authentication key" do
    mail = %{
      "server" => "smtp.example.test",
      "from" => "login@example.test",
      "username" => "mailer",
      "password" => "old-mail-secret"
    }

    old = seed_config("saas.email.mail", mail)
    assert :ok = Repo.without_tenant(&Upgrade202610.run/0)
    refute Repo.get_by(SiteConfig, scope: "global", key: "saas.email.mail")
    row = Repo.get_by!(SiteConfig, scope: "global", key: "authn.email.mail")
    assert row.value["type"] == "cipher"
    refute row.value["value"] == old["value"]
    assert {:ok, ^mail} = Crypto.unseal(row.value["value"], "global", "authn.email.mail")
    assert {:error, _} = Crypto.unseal(row.value["value"], "global", "saas.email.mail")
    assert :ok = Repo.without_tenant(&Upgrade202610.run/0)
    assert Repo.get_by!(SiteConfig, scope: "global", key: "authn.email.mail").value == row.value
  end

  test "legacy empty mail configuration becomes an unconfigured nil value" do
    for key <- ["saas.email.mail", "authn.email.mail"] do
      Repo.delete_all(
        from row in SiteConfig, where: row.scope == "global" and row.key == "authn.email.mail"
      )

      seed_config(key, %{})
      assert :ok = Repo.without_tenant(&Upgrade202610.run/0)
      row = Repo.get_by!(SiteConfig, scope: "global", key: "authn.email.mail")
      assert {:ok, nil} = Crypto.unseal(row.value["value"], "global", "authn.email.mail")
      assert {:ok, nil} = Ankole.Authn.Config.get("mail")
      refute Ankole.Authn.Mailer.configured?()
    end
  end

  test "retired local activations refresh each tenant's configuration in its own context", %{
    tenant: first
  } do
    second = Ankole.DataCase.create_tenant()
    key = "principals.identity_providers.active"

    for tenant <- [first, second] do
      Repo.with_tenant(tenant.id, fn ->
        Repo.insert!(%AppConfig{
          tenant_id: tenant.id,
          scope: "tenant:" <> tenant.id,
          key: key,
          value: %{
            "type" => "plaintext",
            "value" => [
              %{
                "provider_id" => "local-main",
                "adapter_id" => "local",
                "plugin_id" => "core",
                "config_key" => "principals.identity_providers.local-main",
                "enabled" => true
              }
            ]
          }
        })
      end)
    end

    assert :ok = Repo.without_tenant(&Upgrade202610.run/0)

    for tenant <- [first, second] do
      Repo.with_tenant(tenant.id, fn ->
        assert Repo.get_by!(AppConfig, key: key).value["value"] == []
        assert {:ok, []} = Ankole.AppConfigure.get_by_key(key)
      end)
    end
  end

  defp seed_config(key, config) do
    {:ok, ciphertext} = Crypto.seal(config, "global", key)
    value = %{"type" => "cipher", "value" => ciphertext}
    Repo.insert!(%SiteConfig{scope: "global", key: key, value: value})
    value
  end

  defp config("line"),
    do: %{
      "channelId" => "10001",
      "channelSecret" => "old-secret",
      "channelAccessToken" => "old-token"
    }

  defp config("lark"),
    do: %{"appID" => "cli_old_identity", "appSecret" => "old-secret", "domain" => "feishu"}

  defp config("email"),
    do: %{
      "address" => "agent@example.com",
      "imapHost" => "IMAP.example.com",
      "smtpHost" => "smtp.example.com",
      "username" => "Agent",
      "password" => "old-secret"
    }

  defp config("whatsapp"),
    do: %{
      "appId" => "10001",
      "appSecret" => "old-secret",
      "verifyToken" => "old-verify",
      "phoneNumberId" => "20001",
      "accessToken" => "old-token"
    }

  defp config("slack"), do: %{"botToken" => "xoxb-old", "appToken" => "xapp-old"}

  defp config("teams"),
    do: %{
      "appID" => "11111111-2222-3333-4444-555555555555",
      "appPassword" => "old-secret",
      "botTenancy" => "multi_tenant"
    }
end
