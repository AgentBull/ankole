defmodule Mix.Tasks.Ankole.Webapps.Generate do
  @moduledoc """
  Discovers all registered `Ankole.WebappExtension` modules and expands or
  verifies their build-time TypeScript artifacts.

  When no dynamic modules are registered, the task completes as a clean no-op.
  """

  use Mix.Task

  alias Ankole.WebappExtension

  @shortdoc "Generates or checks build-time webapp extension artifacts"
  @requirements ["compile"]

  @impl Mix.Task
  def run(args) when args in [[], ["--write"], ["--check"]] do
    check_only? = args == ["--check"]
    context = build_context()

    case WebappExtension.generate_all(context) do
      {:ok, files} ->
        Enum.each(files, &process_file(&1, check_only?))

      {:error, reason} ->
        Mix.raise("Webapp extension generation failed: #{inspect(reason)}")
    end
  end

  def run(_args), do: Mix.raise("usage: mix ankole.webapps.generate [--write | --check]")

  defp build_context do
    control_plane_root = Path.dirname(Mix.Project.project_file())
    repository_root = Path.expand("../..", control_plane_root)
    webapps_root = Path.expand("../webapps", control_plane_root)

    internals_root =
      case System.get_env("ANKOLE_INTERNALS_PATH") do
        nil -> Path.expand("../../internals", control_plane_root)
        "" -> Path.expand("../../internals", control_plane_root)
        path -> Path.expand(path, control_plane_root)
      end

    %{
      edition: System.get_env("ANKOLE_EDITION") || "foss",
      repository_root: repository_root,
      webapps_root: webapps_root,
      internals_root: internals_root
    }
  end

  defp process_file(%{path: path, content: content, module: module}, true) do
    case File.read(path) do
      {:ok, ^content} ->
        Mix.shell().info("#{Path.relative_to_cwd(path)} is current")

      {:ok, _stale} ->
        Mix.raise(
          "#{path} does not match #{inspect(module)}; run mix ankole.webapps.generate --write"
        )

      {:error, _reason} ->
        Mix.raise(
          "#{path} is missing for #{inspect(module)}; run mix ankole.webapps.generate --write"
        )
    end
  end

  defp process_file(%{path: path, content: content}, false) do
    File.mkdir_p!(Path.dirname(path))

    if File.read(path) != {:ok, content} do
      File.write!(path, content)
      Mix.shell().info("Wrote #{path}")
    end
  end
end
