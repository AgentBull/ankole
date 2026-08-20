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

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
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

  # Specifies which paths to compile per environment.
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
    [ankole: [steps: [:assemble, &copy_runtime_config_support/1]]]
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

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:archdo, ">= 0.0.0", github: "BadBeta/archdo", only: :dev, runtime: false},
      {:phoenix, "~> 1.8.11"},
      {:phoenix_ecto, "~> 4.7"},
      {:ecto_sql, "~> 3.14"},
      {:postgrex, ">= 0.22.4"},
      {:phoenix_html, "~> 4.3"},
      {:phoenix_live_reload, "~> 1.7.0", only: :dev},
      {:opentelemetry_api, "~> 1.5"},
      {:opentelemetry, "~> 1.7"},
      {:opentelemetry_exporter, "~> 1.10"},
      {:req, "~> 0.7"},
      {:telemetry_metrics, "~> 1.1"},
      {:telemetry_poller, "~> 1.3"},
      {:localize, "~> 1.2"},
      {:oban, "~> 2.23"},
      {:crontab, "~> 1.2"},
      {:open_api_spex, "~> 3.22"},
      {:toml_elixir, "~> 3.1"},
      {:tzdata, "~> 1.1"},
      {:hackney, "~> 4.7", override: true},
      {:h2, "~> 0.12", override: true},
      {:dotenvy, "~> 1.1"},
      {:torque, "~> 0.2.7"},
      {:llm_db, "~> 2026.8"},
      {:ankole_kernel, path: "../kernel"},
      {:feishu_openapi, path: "../../libs/feishu_openapi"},
      {:slack_openapi, path: "../../libs/slack_openapi"},
      {:dingtalk_openapi, path: "../../libs/dingtalk_openapi"},
      {:microsoft_openapi, path: "../../libs/microsoft_openapi"},
      {:google_openapi, path: "../../libs/google_openapi"},
      {:wecom_openapi, path: "../../libs/wecom_openapi"},
      {:dns_cluster, "~> 0.2"},
      {:bandit, "~> 1.12"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
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
        "test ../../tools/e2e/suites/lark_real_llm_e2e_test.exs --trace"
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
        "test"
      ]
    ]
  end
end
