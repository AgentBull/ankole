defmodule Mix.Tasks.Compile.AnkoleTargets do
  @moduledoc false
  use Mix.Task.Compiler

  @targets [
    "../../app/control_plane/lib/ankole/pod/position.ex"
  ]

  @impl true
  def run(_args) do
    dest = Mix.Project.compile_path()
    File.mkdir_p!(dest)
    sources = Enum.map(@targets, &Path.expand(&1, __DIR__))

    case Kernel.ParallelCompiler.compile_to_path(sources, dest) do
      {:ok, _modules, _warnings} -> {:ok, []}
      {:error, errors, warnings} -> {:error, errors ++ warnings}
    end
  end
end

defmodule Ankole.Formal.MixProject do
  use Mix.Project

  def project do
    [
      app: :ankole_formal,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_options: [warnings_as_errors: true, debug_info: true],
      compilers: [:ankole_targets | Mix.compilers()],
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto]
    ]
  end

  defp deps do
    [
      {:lynx, git: "https://github.com/josevalim/lynx.git", only: :test}
    ]
  end
end
