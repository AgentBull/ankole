Code.require_file("../../config/support/bootstrap.exs", __DIR__)

defmodule Ankole.Config.BootstrapTest do
  use ExUnit.Case, async: false

  alias Ankole.Config.Bootstrap

  @env_keys [
    "ANKOLE_BOOTSTRAP_BASE",
    "ANKOLE_BOOTSTRAP_PROFILE_LOCAL",
    "ANKOLE_BOOTSTRAP_GLOBAL_LOCAL",
    "ANKOLE_BOOTSTRAP_ONLY_GLOBAL",
    "ANKOLE_BOOTSTRAP_OS",
    "ANKOLE_BOOTSTRAP_PATHS",
    "ANKOLE_SECRET_BASE"
  ]

  setup do
    original_env = Map.new(@env_keys, &{&1, System.get_env(&1)})
    Enum.each(@env_keys, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(original_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)
  end

  test "loads dev dotenv files with local override precedence and OS env priority" do
    root = tmp_root()

    File.write!(Path.join(root, ".env.dev"), """
    ANKOLE_BOOTSTRAP_BASE=from_dev
    ANKOLE_BOOTSTRAP_PROFILE_LOCAL=from_dev
    ANKOLE_BOOTSTRAP_GLOBAL_LOCAL=from_dev
    ANKOLE_BOOTSTRAP_OS=from_dev
    """)

    File.write!(Path.join(root, ".env.dev.local"), """
    ANKOLE_BOOTSTRAP_PROFILE_LOCAL=from_dev_local
    ANKOLE_BOOTSTRAP_GLOBAL_LOCAL=from_dev_local
    """)

    File.write!(Path.join(root, ".env.local"), """
    ANKOLE_BOOTSTRAP_GLOBAL_LOCAL=from_global_local
    ANKOLE_BOOTSTRAP_ONLY_GLOBAL=from_global_local
    ANKOLE_BOOTSTRAP_OS=from_global_local
    """)

    System.put_env("ANKOLE_BOOTSTRAP_OS", "from_os")

    Bootstrap.load_dotenv!(root: root, env: :dev)

    assert System.get_env("ANKOLE_BOOTSTRAP_BASE") == "from_dev"
    assert System.get_env("ANKOLE_BOOTSTRAP_PROFILE_LOCAL") == "from_dev_local"
    assert System.get_env("ANKOLE_BOOTSTRAP_GLOBAL_LOCAL") == "from_global_local"
    assert System.get_env("ANKOLE_BOOTSTRAP_ONLY_GLOBAL") == "from_global_local"
    assert System.get_env("ANKOLE_BOOTSTRAP_OS") == "from_os"
  end

  test "loads test dotenv files and ignores missing local files" do
    root = tmp_root()

    File.write!(Path.join(root, ".env.test"), """
    ANKOLE_BOOTSTRAP_BASE=from_test
    ANKOLE_BOOTSTRAP_GLOBAL_LOCAL=from_test
    """)

    File.write!(Path.join(root, ".env.local"), """
    ANKOLE_BOOTSTRAP_GLOBAL_LOCAL=from_global_local
    """)

    Bootstrap.load_dotenv!(root: root, env: :test)

    assert System.get_env("ANKOLE_BOOTSTRAP_BASE") == "from_test"
    assert System.get_env("ANKOLE_BOOTSTRAP_GLOBAL_LOCAL") == "from_global_local"
  end

  test "loads only global local dotenv file for non dev and test environments" do
    root = tmp_root()

    File.write!(Path.join(root, ".env.prod"), "ANKOLE_BOOTSTRAP_BASE=from_prod\n")
    File.write!(Path.join(root, ".env.local"), "ANKOLE_BOOTSTRAP_ONLY_GLOBAL=from_global_local\n")

    Bootstrap.load_dotenv!(root: root, env: :prod)

    assert System.get_env("ANKOLE_BOOTSTRAP_ONLY_GLOBAL") == "from_global_local"
    assert System.get_env("ANKOLE_BOOTSTRAP_BASE") == nil
  end

  test "parses colon-separated path lists from environment" do
    System.put_env("ANKOLE_BOOTSTRAP_PATHS", "/opt/ankole/plugins: :relative/plugins")

    assert Bootstrap.env_path_list("ANKOLE_BOOTSTRAP_PATHS") == [
             "/opt/ankole/plugins",
             Path.expand("relative/plugins")
           ]

    assert Bootstrap.env_path_list("ANKOLE_BOOTSTRAP_MISSING_PATHS", []) == []
  end

  test "derives the endpoint secret from any configured seed value" do
    Enum.each(["", "x"], fn seed ->
      System.put_env("ANKOLE_SECRET_BASE", seed)

      assert Bootstrap.endpoint_secret_key_base!() ==
               Ankole.Kernel.derive_key(seed, "phoenix.secret_key_base")
    end)
  end

  defp tmp_root do
    root = Path.join(System.tmp_dir!(), "ankole-bootstrap-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    root
  end
end
