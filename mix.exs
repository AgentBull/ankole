defmodule BullX.MixProject do
  use Mix.Project

  def project do
    [
      app: :bullx,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {BullX.Application, []},
      extra_applications: [:logger, :runtime_tools],
      env: [plugin_apps: plugin_apps()]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"] ++ plugin_elixirc_paths()
  defp elixirc_paths(_), do: ["lib"] ++ plugin_elixirc_paths()

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    core_deps = [
      {:archdo, ">= 0.0.0", github: "BadBeta/archdo", only: [:dev, :test], runtime: false},
      {:phoenix, "~> 1.8.5"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:rustler, "~> 0.37.3", runtime: false},
      {:inertia, "~> 2.6"},
      {:open_api_spex, "~> 3.22"},
      {:nimble_options, "~> 1.1"},
      {:swoosh, "~> 1.16"},
      {:req, "~> 0.5"},
      {:req_llm, "~> 1.11"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:localize, "~> 0.28.0"},
      {:toml_elixir, "~> 3.0"},
      {:jason, "~> 1.4"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.11"},
      {:skogsra, "~> 2.5"},
      {:dotenvy, "~> 1.1"},
      {:zoi, "~> 0.17"}
    ]

    merge_deps(core_deps, plugin_project_deps())
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.build": ["compile", "cmd bun run build"],
      "assets.deploy": [
        "compile",
        "cmd bun run build",
        "phx.digest"
      ]
    ]
  end

  defp plugin_elixirc_paths do
    plugin_apps()
    |> Enum.map(&Path.join(["plugins", Atom.to_string(&1), "lib"]))
    |> Enum.filter(&File.dir?/1)
  end

  defp plugin_project_deps do
    plugin_apps()
    |> Enum.flat_map(&plugin_deps_for/1)
  end

  defp plugin_deps_for(app) do
    Mix.Project.in_project(app, Path.join("plugins", Atom.to_string(app)), fn _module ->
      Mix.Project.config()
      |> Keyword.get(:deps, [])
      |> reject_bullx_dep(app)
    end)
  end

  defp plugin_apps do
    "plugins/*/mix.exs"
    |> Path.wildcard()
    |> Enum.map(&Path.dirname/1)
    |> Enum.map(&Path.basename/1)
    |> Enum.map(&String.to_atom/1)
    |> Enum.sort()
  end

  defp reject_bullx_dep(deps, app) do
    case Enum.find(deps, &(dep_app(&1) == :bullx)) do
      nil ->
        deps

      dep ->
        raise ArgumentError,
              "plugin #{inspect(app)} must not depend on :bullx; remove #{inspect(dep)} from its deps"
    end
  end

  defp merge_deps(core_deps, plugin_deps) do
    (core_deps ++ plugin_deps)
    |> Enum.uniq_by(&dep_app/1)
  end

  defp dep_app({app, _req_or_opts}), do: app
  defp dep_app({app, _req, _opts}), do: app
end
