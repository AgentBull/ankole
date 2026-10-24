Code.require_file("../../app/control_plane_core/patches/dependency_patches.exs", __DIR__)

defmodule AnkoleWhatsappAdapter.MixProject do
  use Mix.Project

  def project do
    [
      app: :ankole_whatsapp_adapter,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_options: [warnings_as_errors: true],
      build_path: "_build/#{edition()}",
      deps_path: "../../app/control_plane/deps",
      lockfile: "../../app/control_plane/mix.lock",
      config_path: "../../app/control_plane_core/config/config.exs",
      elixirc_paths: if(Mix.env() == :test, do: ["lib", "test/support"], else: ["lib"]),
      aliases: Ankole.Mix.DependencyPatches.aliases(),
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto]]

  defp edition do
    case System.get_env("ANKOLE_EDITION", "foss") do
      "foss" -> :foss
      "saas" -> :saas
      _ -> raise "ANKOLE_EDITION must be foss or saas"
    end
  end

  defp deps do
    [
      {:ankole_core, path: "../../app/control_plane_core", env: Mix.env()},
      {:req, "~> 0.7.3"},
      {:plug, "~> 1.20"},
      {:ecto, "3.14.2"}
    ]
  end
end
