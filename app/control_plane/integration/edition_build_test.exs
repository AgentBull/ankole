defmodule Ankole.EditionBuildTest do
  use ExUnit.Case, async: false
  @moduletag timeout: 900_000
  @root Path.expand("../../..", __DIR__)

  test "FOSS and SaaS source builds deliver separate releases without source-tree runtime dependencies" do
    parent_native = kernel_native_artifacts()
    assert Map.has_key?(parent_native, "ankole_kernel.so")

    checkout =
      Path.join(System.tmp_dir!(), "ankole-edition-#{System.unique_integer([:positive])}")

    File.mkdir_p!(checkout)
    on_exit(fn -> File.rm_rf!(checkout) end)
    copy_checkout(checkout)
    control_plane = Path.join(checkout, "app/control_plane")

    base_env = [
      {"MIX_ENV", "prod"},
      {"ANKOLE_SECRET_BASE", "edition-build-fixture"},
      {"ANKOLE_FILES_STORE", "fs"},
      {"ANKOLE_FILES_FS_ROOT", Path.join(checkout, "files")},
      {"ANKOLE_AGENT_COMPUTER_IMAGE", "edition-build-fixture"},
      {"ANKOLE_WORKER_RUNTIME_FABRIC_ENDPOINT", "ws://site.example.test/runtime-fabric/worker"},
      {"PHX_SERVER", "false"},
      {"DATABASE_URL", System.fetch_env!("DATABASE_URL")},
      # Cargo locks its shared cache. Native library output stays in the copied checkout.
      {"CARGO_TARGET_DIR", Path.join(@root, "app/kernel/target")},
      {"MIX_BUILD_PATH", nil}
    ]

    # No private checkout exists during the first FOSS build.
    foss = [{"ANKOLE_EDITION", "foss"} | base_env]
    command!(control_plane, "mix", ["assets.build"], foss)
    command!(control_plane, "mix", ["release", "--overwrite"], foss)
    foss_release = Path.join(control_plane, "_build/foss/prod/rel/ankole")
    check_release!(foss_release, foss, false)
    assert kernel_native_artifacts() == parent_native

    File.cp_r!(
      Path.join(@root, "app/control_plane/test/fixtures/edition/internals"),
      Path.join(checkout, "internals")
    )

    saas = [{"ANKOLE_EDITION", "saas"} | base_env]
    webapps = Path.join(checkout, "app/webapps")
    check_webapp_preparation!(checkout, webapps, saas)
    check_private_type_checks!(checkout, webapps, saas)
    command!(control_plane, "mix", ["assets.build"], saas)
    command!(webapps, "bun", ["run", "test"], saas)
    command!(control_plane, "mix", ["release", "--overwrite"], saas)
    saas_release = Path.join(control_plane, "_build/saas/prod/rel/ankole")
    check_release!(saas_release, saas, true)
    check_database_migrations!(control_plane, foss, saas, saas_release)

    test_env =
      List.keystore(saas, "MIX_ENV", 0, {"MIX_ENV", "test"}) ++
        [{"MIX_TEST_PARTITION", "_edition_#{System.unique_integer([:positive])}"}]

    try do
      command!(
        control_plane,
        "mix",
        ["test", "../../internals/control_plane/test/edition_test.exs"],
        test_env
      )
    after
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Ankole.Repo, fn ->
        partition = test_env |> List.keyfind("MIX_TEST_PARTITION", 0) |> elem(1)
        Ankole.Repo.query!("DROP DATABASE IF EXISTS ankole_test#{partition} WITH (FORCE)")
      end)
    end

    # The same checkout must produce FOSS even after a SaaS build.
    command!(control_plane, "mix", ["release", "--overwrite"], foss)
    check_release!(foss_release, foss, false)

    # A missing private source must fail, with no fallback to FOSS.
    File.rename!(
      Path.join(checkout, "internals"),
      Path.join(checkout, "private-source-unavailable")
    )

    {_, status} =
      System.cmd("mix", ["compile"], cd: control_plane, env: saas, stderr_to_stdout: true)

    assert status != 0

    # Move the assembled release away from both source and build directories.
    detached = Path.join(checkout, "detached-release")
    File.cp_r!(saas_release, detached)
    File.rm_rf!(Path.join(checkout, "app/control_plane/_build"))
    check_release!(detached, saas, true)
    assert kernel_native_artifacts() == parent_native
  end

  defp check_webapp_preparation!(checkout, webapps, env) do
    dependencies = Path.join(checkout, "internals/webapps/node_modules")

    command!(
      webapps,
      "bun",
      ["-e", "import { webappEntries } from './scripts/edition.ts'; webappEntries()"],
      env
    )

    assert {:error, :enoent} = File.lstat(dependencies)

    script = """
    const worker = `
      import { prepareEdition } from './scripts/edition.ts';
      console.log('ready');
      await Bun.stdin.text();
      prepareEdition();
    `;
    const children = Array.from({ length: 8 }, () =>
      Bun.spawn(['bun', '-e', worker], { stdin: 'pipe', stdout: 'pipe', stderr: 'pipe' })
    );
    await Promise.all(children.map(async child => {
      const reader = child.stdout.getReader();
      const { value } = await reader.read();
      if (new TextDecoder().decode(value).trim() !== 'ready') throw new Error('Worker not ready');
      reader.releaseLock();
    }));
    for (const child of children) child.stdin.end();
    const results = await Promise.all(children.map(async child => ({
      status: await child.exited,
      error: await new Response(child.stderr).text()
    })));
    for (const result of results) {
      if (result.status !== 0) throw new Error(result.error);
    }
    """

    for _ <- 1..3 do
      assert File.rm(dependencies) in [:ok, {:error, :enoent}]
      command!(webapps, "bun", ["-e", script], env)

      assert File.stat!(dependencies).inode ==
               File.stat!(Path.join(webapps, "node_modules")).inode
    end
  end

  defp check_private_type_checks!(checkout, webapps, env) do
    invalid = Path.join(checkout, "internals/webapps/lint-regression.ts")
    File.write!(invalid, "export const invalid: string = 1\n")

    try do
      for task <- ["type-check", "lint"] do
        {output, status} =
          System.cmd("bun", ["run", task], cd: webapps, env: env, stderr_to_stdout: true)

        assert status != 0
        assert output =~ "lint-regression.ts"
        assert output =~ "TS2322"
      end
    after
      File.rm!(invalid)
    end

    command!(webapps, "bun", ["run", "lint"], env)
  end

  defp check_database_migrations!(directory, foss, saas, release) do
    for origin <- [:empty, :foss_upgrade] do
      name = "ankole_test_pre_#{origin}_#{System.unique_integer([:positive])}"

      url =
        System.fetch_env!("DATABASE_URL")
        |> URI.parse()
        |> Map.put(:path, "/" <> name)
        |> URI.to_string()

      foss = List.keystore(foss, "DATABASE_URL", 0, {"DATABASE_URL", url})
      saas = List.keystore(saas, "DATABASE_URL", 0, {"DATABASE_URL", url})

      Ecto.Adapters.SQL.Sandbox.unboxed_run(Ankole.Repo, fn ->
        Ankole.Repo.query!("CREATE DATABASE #{name} WITH TEMPLATE template0 ENCODING 'UTF8'")
      end)

      try do
        if origin == :foss_upgrade do
          command!(directory, "mix", ["ecto.migrate", "--to", "20261016000300", "--quiet"], foss)

          seed = """
          Ecto.Migrator.with_repo(Ankole.Repo, fn repo ->
            repo.query!("UPDATE tenants SET display_name = 'Edition upgrade fixture' WHERE slug = 'default'")
            repo.query!("INSERT INTO browser_sessions (id, generation, expires_at, admin_auth, inserted_at, updated_at) VALUES ('019a2b00-0000-7000-8000-000000000010', 1, NOW() + INTERVAL '1 day', jsonb_build_object('principal_uid', 'obsolete-cookie'), NOW(), NOW())")
            repo.query!("INSERT INTO browser_login_transactions (id, browser_id, generation, purpose, expires_at, tenant_id, inserted_at, updated_at) VALUES ('019a2b00-0000-7000-8000-000000000011', '019a2b00-0000-7000-8000-000000000010', 1, 'console', NOW() + INTERVAL '1 hour', '019a2b00-0000-7000-8000-000000000001', NOW(), NOW())")
          end)
          """

          command!(directory, "mix", ["run", "--no-start", "-e", seed], foss)
        end

        command!(
          release,
          Path.join(release, "bin/ankole"),
          ["eval", "Ankole.Release.migrate()"],
          saas
        )

        verification = """
        Ecto.Migrator.with_repo(Ankole.Repo, fn repo ->
          %{rows: [[0]]} = repo.query!("SELECT count(*) FROM browser_login_transactions")
          %{rows: [[0]]} = repo.query!("SELECT count(*) FROM browser_authentications")
          %{rows: [[1]]} = repo.query!("SELECT count(*) FROM schema_migrations WHERE version = 20990101000000")
          %{rows: [["edition_fixture"]]} = repo.query!("SELECT to_regclass('edition_fixture')::text")
          if #{inspect(origin == :foss_upgrade)} do
            %{rows: [["Edition upgrade fixture"]]} = repo.query!("SELECT display_name FROM tenants WHERE slug = 'default'")
          end
        end)
        """

        command!(release, Path.join(release, "bin/ankole"), ["eval", verification], saas)
        assert command!(directory, "mix", ["ecto.migrations"], saas) =~ "create_edition_fixture"
        command!(directory, "mix", ["ecto.rollback", "--step", "1", "--quiet"], saas)
        command!(directory, "mix", ["ecto.migrate", "--quiet"], saas)
      after
        command!(directory, "mix", ["ecto.drop", "--force", "--quiet"], foss)
      end
    end
  end

  defp check_release!(release, env, saas?) do
    expression = """
    Application.load(:ankole)
    expected = #{inspect(saas?)}
    check = fn label, actual, expected_value ->
      unless actual == expected_value,
        do: raise(label <> ": expected " <> inspect(expected_value) <> ", got " <> inspect(actual))
    end
    check.("private router", Code.ensure_loaded?(Ankole.EditionFixture.Router), expected)
    check.("production test support", Code.ensure_loaded?(Ankole.EditionFixture.TestSupport), false)
    manifest = AnkoleWeb.Assets.directory() |> Path.join("manifest.json") |> File.read!() |> Ankole.JSON.decode!()
    check.("private frontend manifest", Enum.any?(manifest, fn {_key, value} -> value["name"] == "edition-fixture" end), expected)
    css = Path.wildcard(Path.join(AnkoleWeb.Assets.directory(), "css/*.css")) |> Enum.map_join(&File.read!/1)
    check.("private CSS", String.contains?(css, "123.456px"), expected)
    locales = Ankole.I18n.Loader.load_all(Ankole.I18n.Config.locales_dir())
    check.("private catalog", Map.has_key?(locales["en-US"].messages, "edition_fixture.message"), expected)
    check.("private migrations", Enum.any?(Ankole.Migrations.paths(), &String.ends_with?(&1, "internal_migrations")), expected)
    :ok = Ankole.Migrations.validate!()
    if expected do
      :ok = AnkoleWeb.SiteAdminConsole.validate!()
      :ok = Ankole.IdentityProviders.SiteSources.validate!()
      check.("site Worker URL", AnkoleWeb.Plugs.RequestHost.worker_allowed?(URI.parse("https://site.example.test/runtime-fabric/worker")), true)
      check.("Pod Worker URL", AnkoleWeb.Plugs.RequestHost.worker_allowed?(URI.parse("https://pod.example.test/runtime-fabric/worker")), false)
      check.("foreign Worker URL", AnkoleWeb.Plugs.RequestHost.worker_allowed?(URI.parse("https://attacker.test/runtime-fabric/worker")), false)
      {:error, _} = Ankole.IdentityProviders.SiteSources.authenticate("fixture-site", :untrusted)
      {:ok, pid} = Ankole.AppConfigure.Registry.start_link([])
      {:ok, _} = Ankole.AppConfigure.Registry.require_key("fixture.edition")
      GenServer.stop(pid)
      {:ok, pid} = Ankole.AppConfigure.Registry.start_link([])
      {:ok, _} = Ankole.AppConfigure.Registry.require_key("fixture.edition")
      GenServer.stop(pid)
      conn = Plug.Test.conn(:get, "https://attacker.test/assets/manifest.json")
      %{status: 400, halted: true} = AnkoleWeb.Plugs.RequestHost.call(conn, [])
      conn = Plug.Test.conn(:get, "https://site.example.test/edition-fixture")
      conn = AnkoleWeb.Plugs.RequestHost.call(conn, [])
      %{status: 200, assigns: %{browser_login_mode: :add}} = Ankole.EditionFixture.Router.call(conn, Ankole.EditionFixture.Router.init([]))
      tags = AnkoleWeb.Assets.entry_tags(conn, "edition-fixture") |> IO.iodata_to_binary()
      check.("private frontend tags", String.contains?(tags, "/assets/js/edition-fixture-"), true)
    end
    IO.puts("edition-release-verified")
    """

    output = command!(release, Path.join(release, "bin/ankole"), ["eval", expression], env)
    assert output =~ "edition-release-verified"
  end

  defp copy_checkout(checkout) do
    for relative <- [
          "app/control_plane",
          "app/control_plane_core",
          "app/kernel",
          "plugins",
          "app/webapps",
          "app/locales",
          "tools/openapi-client-generator"
        ] do
      copy_source(Path.join(@root, relative), Path.join(checkout, relative))
    end

    for relative <- [
          "libs",
          "node_modules",
          "app/library",
          "app/agent_computer",
          "tools/e2e",
          "tools/fake-feishu"
        ] do
      target = Path.join(checkout, relative)
      File.mkdir_p!(Path.dirname(target))
      File.ln_s!(Path.join(@root, relative), target)
    end

    for file <- ["package.json", "bun.lock", "tsconfig.json", "tsconfig.base.json"] do
      File.cp!(Path.join(@root, file), Path.join(checkout, file))
    end

    File.ln_s!(
      Path.join(@root, "app/control_plane/deps"),
      Path.join(checkout, "app/control_plane/deps")
    )

    for relative <- ["app/webapps/node_modules", "tools/openapi-client-generator/node_modules"] do
      File.ln_s!(Path.join(@root, relative), Path.join(checkout, relative))
    end
  end

  defp kernel_native_artifacts do
    :ankole_kernel
    |> Application.app_dir("priv/native/*")
    |> Path.wildcard()
    |> Map.new(fn path -> {Path.basename(path), :crypto.hash(:sha256, File.read!(path))} end)
  end

  defp copy_source(source, target) do
    File.mkdir_p!(target)

    for name <- File.ls!(source),
        name not in ["_build", "deps", "node_modules", "output", "target"] and
          not String.starts_with?(name, "mix_lock_") and
          not String.starts_with?(name, "mix_pubsub_") do
      path = Path.join(source, name)
      destination = Path.join(target, name)
      if File.dir?(path), do: copy_source(path, destination), else: File.cp!(path, destination)
    end
  end

  defp command!(directory, executable, args, env) do
    {output, status} =
      System.cmd(executable, args, cd: directory, env: env, stderr_to_stdout: true)

    assert status == 0,
           "#{executable} #{Enum.join(args, " ")} failed:\n#{String.slice(output, -6000, 6000)}"

    output
  end
end
