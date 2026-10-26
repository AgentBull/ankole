Code.require_file("patches/dependency_patches.exs", __DIR__)

defmodule Ankole.MixProject do
  use Mix.Project

  def project do
    [
      app: :ankole,
      version: "0.1.1",
      ankole_edition: edition(),
      build_path: "_build/#{edition()}",
      test_paths: test_paths(),
      test_load_filters: [
        &(String.ends_with?(&1, "_test.exs") and not String.starts_with?(&1, "test/fixtures/"))
      ],
      test_ignore_filters: [
        &String.starts_with?(&1, "test/fixtures/"),
        &(&1 == "test/ankole/persistence_boundary.exs")
      ],
      elixir: "~> 1.20",
      elixirc_options: [warnings_as_errors: true],
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      consolidate_protocols: Mix.env() != :dev,
      aliases: aliases(),
      deps: deps(),
      releases: releases(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  def application do
    [
      mod: {Ankole.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [
        precommit: :test,
        "ankole.plugins.test": :test,
        "e2e.ai_gateway_real_provider": :test,
        "e2e.gate": :test,
        "e2e.perf": :test,
        "e2e.chaos": :test,
        "e2e.real_llm": :test
      ]
    ]
  end

  defp elixirc_paths(:test),
    do:
      ["lib", "test/support" | e2e_support_paths()] ++
        plugin_paths("lib") ++
        plugin_paths("test/support") ++
        internal_paths(["control_plane/lib", "control_plane/test/support"])

  defp elixirc_paths(_),
    do: ["lib"] ++ plugin_paths("lib") ++ internal_paths(["control_plane/lib"])

  # Repo-root e2e support modules (harness, scenarios) and the fake Feishu
  # platform owned by tools/fake-feishu compile into :test alongside
  # test/support. The e2e suites themselves stay outside the compile path so
  # plain `mix test` never runs them.
  defp e2e_support_paths do
    repo_root = Path.expand("../..", __DIR__)

    [
      Path.join(repo_root, "tools/e2e/support"),
      Path.join(repo_root, "tools/fake-feishu/platform"),
      Path.join(repo_root, "tools/fake-feishu/lib")
    ]
  end

  defp plugin_paths(directory) do
    roots = [Path.expand("../../plugins", __DIR__)] ++ internal_paths(["plugins"])

    for root <- roots,
        path <- Path.wildcard(Path.join(root, "*/#{directory}")),
        File.dir?(path),
        do: path
  end

  defp edition do
    case System.get_env("ANKOLE_EDITION", "foss") do
      "foss" -> :foss
      "saas" -> :saas
      _ -> raise "ANKOLE_EDITION must be foss or saas"
    end
  end

  defp internal_paths(paths) do
    if edition() == :saas do
      Enum.map(paths, &Path.expand("../../internals/#{&1}", __DIR__))
    else
      []
    end
  end

  defp test_paths,
    do: ["test"] ++ plugin_paths("test") ++ internal_paths(["control_plane/test"])

  defp prepare_webapps(_args) do
    if edition() == :saas do
      for relative <- [
            "control_plane/lib",
            "control_plane/config.exs",
            "control_plane/priv/repo/migrations",
            "control_plane/test/test_helper.exs",
            "webapps/entries.json",
            "locales"
          ] do
        unless File.exists?(Path.expand("../../internals/#{relative}", __DIR__)),
          do: raise("Missing SaaS source: internals/#{relative}")
      end
    end

    {output, status} =
      System.cmd("bun", ["run", "scripts/prepare-edition.ts"],
        cd: Path.expand("../webapps", __DIR__),
        stderr_to_stdout: true
      )

    if status != 0, do: Mix.raise(output)
  end

  defp validate_build(_args) do
    :ok = Ankole.Migrations.validate!()
    :ok = Ankole.IdentityProviders.SiteSources.validate!()

    if edition() == :saas do
      for {key, callbacks} <- [
            http_entry: [init: 1, call: 2, __routes__: 0],
            host_policy: [classify: 1, domain: 0, pod_origin: 1, canonical_origin: 1],
            edition_config: [definitions: 0, patterns: 0, runtime_config: 1]
          ] do
        module = Application.fetch_env!(:ankole, key)

        unless Code.ensure_loaded?(module) and
                 Enum.all?(callbacks, fn {name, arity} ->
                   function_exported?(module, name, arity)
                 end),
               do: Mix.raise("Invalid SaaS build module for #{key}: #{inspect(module)}")
      end
    end
  end

  defp releases do
    [
      ankole: [
        applications: [aws_credentials: :load],
        steps: [
          :assemble,
          &remove_dependency_native_copies/1,
          &copy_runtime_config_support/1,
          &copy_build_resources/1
        ]
      ]
    ]
  end

  # Rustler copies a build artifact of each dependency crate that declares a
  # cdylib crate type. crc-fast, which the OpenDAL S3 service uses, is one, so
  # the kernel priv directory gets its rlib as `crc_fast.so`. Nothing loads that
  # file, so the release does not ship it.
  defp remove_dependency_native_copies(%Mix.Release{} = release) do
    release.path
    |> Path.join("lib/ankole_kernel-*/priv/native/*")
    |> Path.wildcard()
    |> Enum.reject(&(Path.basename(&1) == "ankole_kernel.so"))
    |> Enum.each(&File.rm!/1)

    release
  end

  defp copy_runtime_config_support(%Mix.Release{} = release) do
    source = Path.join(__DIR__, "config/support/bootstrap.exs")

    target =
      Path.join([
        release.path,
        "releases",
        release.version,
        "support",
        "bootstrap.exs"
      ])

    File.mkdir_p!(Path.dirname(target))
    File.cp!(source, target)
    release
  end

  defp copy_build_resources(%Mix.Release{} = release) do
    :ok = Ankole.Migrations.validate!()
    application = Path.join(release.path, "lib/ankole-#{release.applications.ankole[:vsn]}")
    artifacts = Path.expand("_build/#{edition()}", __DIR__)

    for {source, destination} <- [
          {Path.join(artifacts, "webapps/assets"), "priv/static/assets"},
          {Path.join(artifacts, "locales"), "priv/locales"}
        ] do
      target = Path.join(application, destination)
      File.rm_rf!(target)
      File.cp_r!(source, target)
    end

    target = Path.join(application, "priv/repo/internal_migrations")
    File.rm_rf!(target)

    if edition() == :saas do
      [source] = internal_paths(["control_plane/priv/repo/migrations"])
      File.cp_r!(source, target)
    end

    release
  end

  defp deps do
    [
      {:archdo, ">= 0.0.0", github: "BadBeta/archdo", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.4", []},
      {:phoenix, "~> 1.8.15"},
      {:phoenix_pubsub, "~> 2.4"},
      {:phoenix_ecto, "~> 4.7"},
      # Repo scopes JoinExpr predicates. Update this pin with its SQL contract tests.
      {:ecto, "3.14.2"},
      {:ecto_sql, "~> 3.14"},
      {:postgrex, ">= 0.22.4"},
      {:phoenix_html, "~> 4.3"},
      {:phoenix_live_reload, "~> 1.7.0", only: :dev},
      {:opentelemetry_api, "~> 1.5"},
      {:opentelemetry, "~> 1.7"},
      {:opentelemetry_exporter, "~> 1.11"},
      {:req, "~> 0.7.3"},
      {:finch, "~> 0.24"},
      {:aws_signature, "~> 0.4.3"},
      {:aws_credentials, "~> 1.1.1", runtime: false},
      {:kubereq, "~> 0.4.5"},
      {:gen_smtp, "~> 1.3"},
      {:codepagex, "~> 0.1.13"},
      {:mint_web_socket, "~> 1.0"},
      {:localize, "~> 1.3"},
      {:oban, "~> 2.24"},
      {:crontab, "~> 1.2"},
      {:open_api_spex, "~> 3.22"},
      {:open_feature, "~> 0.1"},
      {:attesto, "== 2.6.1"},
      {:attesto_client, "== 2.5.0"},
      {:ash, "== 3.36.1"},
      {:ash_postgres, "== 2.15.1"},
      {:ash_state_machine, "== 0.2.13"},
      {:ash_json_api, "== 1.7.1"},
      {:toml_elixir, "~> 3.2"},
      {:yaml_elixir, "~> 2.12"},
      {:ex_json_schema, "~> 0.11"},
      {:tzdata, "~> 1.2"},
      {:dotenvy, "~> 1.2"},
      {:torque, "~> 0.5.0"},
      {:protox, "~> 2.1"},
      {:llm_db, "~> 2026.10"},
      {:ankole_kernel, path: "../kernel"},
      {:dns_cluster, "~> 0.3"},
      {:bandit, "~> 1.12"},
      {:plug, "~> 1.20"},
      {:telemetry, "~> 1.4.2"},
      {:im_transport, path: "../../libs/im_transport"},
      {:feishu_protocol, path: "../../libs/feishu_protocol"}
    ]
  end

  defp aliases do
    Ankole.Mix.DependencyPatches.aliases() ++
      [
        setup: ["deps.get", "ecto.setup"],
        compile: [&prepare_webapps/1, "compile", &validate_build/1],
        "ecto.migrate": [
          fn args ->
            Mix.Task.run("loadpaths", args)
            Mix.Tasks.Ecto.Migrate.run(args, &Ankole.Migrations.migrate/4)
          end
        ],
        "ecto.rollback": [
          fn args ->
            Mix.Task.run("loadpaths", args)
            Mix.Tasks.Ecto.Rollback.run(args, &Ankole.Migrations.migrate/4)
          end
        ],
        "ecto.migrations": [
          fn args ->
            Mix.Task.run("loadpaths", args)
            Mix.Tasks.Ecto.Migrations.run(args, &Ankole.Migrations.status/3)
          end
        ],
        "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
        "ecto.reset": ["ecto.drop", "ecto.setup"],
        "e2e.gate": [
          "ecto.create --quiet",
          "ecto.migrate --quiet",
          "test ../../tools/e2e/suites/lark_transport_e2e_test.exs " <>
            "../../tools/e2e/suites/lark_main_flow_e2e_test.exs " <>
            "../../tools/e2e/suites/lark_lifecycle_e2e_test.exs " <>
            "../../tools/e2e/suites/slack_transport_e2e_test.exs " <>
            "../../tools/e2e/suites/slack_main_flow_e2e_test.exs " <>
            "../../tools/e2e/suites/slack_lifecycle_e2e_test.exs " <>
            "../../tools/e2e/suites/dingtalk_transport_e2e_test.exs " <>
            "../../tools/e2e/suites/wecom_transport_e2e_test.exs " <>
            "../../tools/e2e/suites/worker_computer_e2e_test.exs " <>
            "../../tools/e2e/suites/runtime_fabric_e2e_test.exs " <>
            "../../tools/e2e/suites/compose_upgrade_e2e_test.exs " <>
            "../../tools/e2e/suites/authn_compose_e2e_test.exs " <>
            "../../tools/e2e/suites/schedule_e2e_test.exs --trace"
        ],
        "e2e.perf": [
          "ecto.create --quiet",
          "ecto.migrate --quiet",
          "test ../../tools/e2e/suites/concurrency_perf_e2e_test.exs --trace"
        ],
        "e2e.chaos": [
          "ecto.create --quiet",
          "ecto.migrate --quiet",
          "test ../../tools/e2e/suites/chaos_e2e_test.exs --trace"
        ],
        "e2e.real_llm": [
          "ecto.create --quiet",
          "ecto.migrate --quiet",
          "test ../../tools/e2e/suites/lark_real_llm_e2e_test.exs " <>
            "../../tools/e2e/suites/lark_workflow_real_llm_e2e_test.exs " <>
            "../../tools/e2e/suites/conversations_cli_real_llm_e2e_test.exs " <>
            "../../tools/e2e/suites/pod_skill_lessons_real_llm_e2e_test.exs " <>
            "../../tools/e2e/suites/pod_content_real_llm_e2e_test.exs --trace"
        ],
        "e2e.ai_gateway_real_provider": [
          "ecto.create --quiet",
          "ecto.migrate --quiet",
          "run ../../tools/e2e/ai_gateway_real_provider_e2e.exs"
        ],
        test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
        "assets.build": ["cmd --cd ../webapps bun run build"],
        "assets.deploy": ["assets.build", "phx.digest"],
        precommit: [
          "compile --warnings-as-errors --no-all-warnings",
          "deps.unlock --unused",
          "format",
          "credo --strict",
          "test"
        ]
      ]
  end
end
