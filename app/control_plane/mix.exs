defmodule Ankole.MixProject do
  use Mix.Project

  def project do
    [
      app: :ankole,
      version: "0.1.1",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
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
        "e2e.ai_gateway_real_provider": :test,
        "e2e.gate": :test,
        "e2e.perf": :test,
        "e2e.chaos": :test,
        "e2e.real_llm": :test
      ]
    ]
  end

  defp elixirc_paths(:test),
    do: ["lib", "test/support" | e2e_support_paths()] ++ plugin_elixirc_paths()

  defp elixirc_paths(_), do: ["lib"] ++ plugin_elixirc_paths()

  # Repo-root e2e support modules (harness, scenarios) and the fake Feishu
  # platform owned by tools/fake-feishu compile into :test alongside
  # test/support. The e2e suites themselves stay outside the compile path so
  # plain `mix test` never runs them.
  defp e2e_support_paths do
    repo_root = Path.expand("../..", __DIR__)

    [
      Path.join(repo_root, "tools/e2e/support"),
      Path.join(repo_root, "tools/fake-feishu/platform")
    ]
  end

  defp plugin_elixirc_paths do
    repo_root = Path.expand("../..", __DIR__)

    [
      Path.join(repo_root, "plugins/*/lib"),
      Path.join(repo_root, "internals/plugins/*/lib")
    ]
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.filter(&File.dir?/1)
  end

  defp releases do
    [
      ankole: [
        applications: [aws_credentials: :load],
        steps: [:assemble, &remove_dependency_native_copies/1, &copy_runtime_config_support/1]
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

  defp deps do
    [
      {:archdo, ">= 0.0.0", github: "BadBeta/archdo", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
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
      {:req, "~> 0.7"},
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
      {:boruta, "2.3.8"},
      {:toml_elixir, "~> 3.2"},
      {:yaml_elixir, "~> 2.12"},
      {:ex_json_schema, "~> 0.11"},
      {:pgvector, "~> 0.4"},
      {:tzdata, "~> 1.2"},
      {:hackney, "~> 4.8", override: true},
      {:h2, "~> 0.12", override: true},
      {:dotenvy, "~> 1.2"},
      {:torque, "~> 0.5.0"},
      {:llm_db, "~> 2026.10"},
      {:ankole_kernel, path: "../kernel"},
      {:feishu_openapi, path: "../../libs/feishu_openapi"},
      {:slack_openapi, path: "../../libs/slack_openapi"},
      {:dingtalk_openapi, path: "../../libs/dingtalk_openapi"},
      {:microsoft_openapi, path: "../../libs/microsoft_openapi"},
      {:google_openapi, path: "../../libs/google_openapi"},
      {:wecom_openapi, path: "../../libs/wecom_openapi"},
      {:dns_cluster, "~> 0.3"},
      {:bandit, "~> 1.12"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.migrate": [
        fn args ->
          Mix.Task.run("loadpaths", args)
          Mix.Tasks.Ecto.Migrate.run(args, &Ankole.Upgrade202610.migrate/4)
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
          "../../tools/e2e/suites/conversations_cli_real_llm_e2e_test.exs --trace"
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
