defmodule Ankole.VersionTest do
  use ExUnit.Case, async: false

  alias Ankole.Version

  @version_env "ANKOLE_VERSION"

  setup do
    previous_version = System.get_env(@version_env)
    System.delete_env(@version_env)

    on_exit(fn -> restore_env(@version_env, previous_version) end)
  end

  test "uses the image-provided version when present" do
    System.put_env(@version_env, "  v26.07.8  ")

    assert Version.current() == "v26.07.8"
  end

  test "falls back to a non-empty source checkout version" do
    version = Version.current()

    assert is_binary(version)
    assert String.trim(version) != ""
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
