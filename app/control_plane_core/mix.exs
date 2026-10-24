defmodule AnkoleCore.MixProject do
  use Mix.Project

  def project do
    [
      app: :ankole_core,
      version: "0.1.1",
      elixir: "~> 1.20",
      elixirc_options: [warnings_as_errors: true],
      build_path: "_build/#{edition()}",
      deps_path: "../control_plane/deps",
      lockfile: "../control_plane/mix.lock",
      elixirc_paths:
        if(Mix.env() == :test, do: ["lib", "test/support"], else: ["lib"]) ++ internal_paths(),
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger, :runtime_tools]]

  defp edition do
    case System.get_env("ANKOLE_EDITION", "foss") do
      "foss" -> :foss
      "saas" -> :saas
      _ -> raise "ANKOLE_EDITION must be foss or saas"
    end
  end

  defp internal_paths do
    if edition() == :saas,
      do: [Path.expand("../../internals/control_plane/lib", __DIR__)],
      else: []
  end

  defp deps do
    [
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
      {:bandit, "~> 1.12"}
    ]
  end
end
