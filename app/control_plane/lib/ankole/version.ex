defmodule Ankole.Version do
  @moduledoc """
  Resolves the operator-visible Ankole build version.

  Published images provide `ANKOLE_VERSION`. Source checkouts fall back to Git
  so local, uncommitted work is visibly marked as dirty.
  """

  @git_args ~w(describe --tags --always --dirty)
  @development_version "development"

  @doc "Returns the current image version or source-checkout Git description."
  @spec current() :: String.t()
  def current do
    System.get_env("ANKOLE_VERSION")
    |> present_value()
    |> then(&(&1 || git_version()))
  end

  defp git_version do
    with git when is_binary(git) <- System.find_executable("git"),
         {version, 0} <- System.cmd(git, @git_args, stderr_to_stdout: true),
         version when is_binary(version) <- present_value(version) do
      version
    else
      _missing_or_failed -> @development_version
    end
  rescue
    ErlangError -> @development_version
  end

  defp present_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp present_value(_value), do: nil
end
