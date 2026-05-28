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
      extra_applications: [:logger, :runtime_tools, :cachetastic],
      env: [plugin_apps: plugin_apps(), internal_plugin_apps: internal_plugin_apps()]
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
      {:phoenix, "~> 1.8.7"},
      {:phoenix_ecto, "~> 4.7"},
      {:ecto_sql, "~> 3.14"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.3"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:rustler, "~> 0.37.3", runtime: false},
      {:inertia, "~> 2.6"},
      {:open_api_spex, "~> 3.22"},
      {:nimble_options, "~> 1.1"},
      {:swoosh, "~> 1.25"},
      {:req, "~> 0.5"},
      {:req_llm, "~> 1.11"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:localize, "~> 0.37.0"},
      {:toml_elixir, "~> 3.0"},
      {:jason, "~> 1.4"},
      {:bandit, "~> 1.11"},
      {:skogsra, "~> 2.5"},
      {:dotenvy, "~> 1.1"},
      {:zoi, "~> 0.18"},
      {:cachetastic, "~> 1.0"},
      {:redix, "~> 1.5"}
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
    plugin_dirs()
    |> Enum.map(fn {_app, dir} -> Path.join(dir, "lib") end)
    |> Enum.filter(&File.dir?/1)
  end

  defp plugin_project_deps do
    plugin_dirs()
    |> Enum.flat_map(fn {app, dir} -> plugin_deps_for(app, dir) end)
  end

  defp plugin_deps_for(app, dir) do
    Mix.Project.in_project(app, dir, fn _module ->
      Mix.Project.config()
      |> Keyword.get(:deps, [])
      |> reject_bullx_dep(app)
    end)
  end

  defp plugin_apps do
    plugin_dirs()
    |> Enum.map(&elem(&1, 0))
  end

  defp internal_plugin_apps do
    plugin_dirs()
    |> Enum.filter(fn {_app, dir} -> String.starts_with?(dir, "internals/plugins/") end)
    |> Enum.map(&elem(&1, 0))
  end

  defp plugin_dirs do
    ["plugins/*/mix.exs", "internals/plugins/*/mix.exs"]
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.map(&Path.dirname/1)
    |> Enum.map(&{&1 |> Path.basename() |> String.to_atom(), &1})
    |> Enum.sort()
    |> reject_duplicate_plugin_dirs()
  end

  defp reject_duplicate_plugin_dirs(plugin_dirs) do
    plugin_dirs
    |> Enum.frequencies_by(&elem(&1, 0))
    |> Enum.filter(fn {_app, count} -> count > 1 end)
    |> case do
      [] ->
        plugin_dirs

      duplicates ->
        apps = duplicates |> Enum.map(&elem(&1, 0)) |> Enum.sort()
        raise ArgumentError, "duplicate BullX plugin app directories: #{inspect(apps)}"
    end
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
