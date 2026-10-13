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

  @files_env_keys ~w(
    ANKOLE_FILES_STORE ANKOLE_FILES_FS_ROOT
    ANKOLE_FILES_S3_BUCKET ANKOLE_FILES_S3_REGION ANKOLE_FILES_S3_ENDPOINT
    ANKOLE_FILES_S3_ROOT ANKOLE_FILES_S3_ACCESS_KEY_ID ANKOLE_FILES_S3_SECRET_ACCESS_KEY
    ANKOLE_FILES_AZBLOB_CONTAINER ANKOLE_FILES_AZBLOB_ENDPOINT ANKOLE_FILES_AZBLOB_SAS_TOKEN
    ANKOLE_FILES_D1_ACCOUNT_ID ANKOLE_FILES_D1_DATABASE_ID ANKOLE_FILES_D1_TOKEN
    ANKOLE_FILES_D1_TABLE ANKOLE_FILES_D1_KEY_FIELD ANKOLE_FILES_D1_VALUE_FIELD
    ANKOLE_FILES_COS_BUCKET ANKOLE_FILES_COS_ENDPOINT
    ANKOLE_FILES_POSTGRESQL_CONNECTION_STRING ANKOLE_FILES_POSTGRESQL_TABLE
    ANKOLE_FILES_POSTGRESQL_KEY_FIELD ANKOLE_FILES_POSTGRESQL_VALUE_FIELD
    ANKOLE_FILES_OSS_BUCKET ANKOLE_FILES_OSS_ENDPOINT
    ANKOLE_FILES_TOS_BUCKET ANKOLE_FILES_TOS_ENDPOINT ANKOLE_FILES_TOS_REGION
    ANKOLE_FILES_GCS_BUCKET ANKOLE_FILES_GCS_CREDENTIAL_PATH
    ANKOLE_FILES_SFTP_ENDPOINT ANKOLE_FILES_SFTP_KEY ANKOLE_FILES_SFTP_KNOWN_HOSTS_STRATEGY
    ANKOLE_FILES_WEBDAV_ENDPOINT ANKOLE_FILES_WEBDAV_PASSWORD
  )

  setup do
    keys = @env_keys ++ @files_env_keys
    original_env = Map.new(keys, &{&1, System.get_env(&1)})
    Enum.each(keys, &System.delete_env/1)

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

  test "dotenv quotes, export and interpolation use Dotenvy semantics" do
    root = tmp_root()

    File.write!(Path.join(root, ".env.dev"), """
    export ANKOLE_BOOTSTRAP_BASE="quoted value"
    ANKOLE_BOOTSTRAP_GLOBAL_LOCAL="${ANKOLE_BOOTSTRAP_BASE}/tail"
    """)

    Bootstrap.load_dotenv!(root: root, env: :dev)

    assert System.get_env("ANKOLE_BOOTSTRAP_BASE") == "quoted value"
    assert System.get_env("ANKOLE_BOOTSTRAP_GLOBAL_LOCAL") == "quoted value/tail"
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

  test "builds remote store specs with credentials and upstream field names" do
    specs = [
      %{
        scheme: "s3",
        bucket: "files",
        region: "auto",
        access_key_id: "id",
        secret_access_key: "secret"
      },
      %{
        scheme: "azblob",
        container: "files",
        endpoint: "https://example.blob.core.windows.net",
        sas_token: "token"
      },
      %{
        scheme: "d1",
        account_id: "account",
        database_id: "database",
        token: "token",
        table: "objects",
        key_field: "key",
        value_field: "value"
      },
      %{scheme: "cos", bucket: "files-123", endpoint: "https://cos.ap-singapore.myqcloud.com"},
      %{
        scheme: "postgresql",
        connection_string: "postgresql://user@localhost/objects",
        table: "objects",
        key_field: "key",
        value_field: "value"
      },
      %{scheme: "oss", bucket: "files", endpoint: "https://oss-ap-southeast-1.aliyuncs.com"},
      %{
        scheme: "tos",
        bucket: "files",
        endpoint: "https://tos-ap-southeast-1.volces.com",
        region: "ap-southeast-1"
      },
      %{scheme: "gcs", bucket: "files", credential_path: "/run/secrets/gcs.json"},
      %{
        scheme: "sftp",
        endpoint: "ssh://example.com",
        key: "/run/secrets/sftp",
        known_hosts_strategy: "strict"
      },
      %{scheme: "webdav", endpoint: "https://example.com/dav", password: "secret"}
    ]

    Enum.each(specs, fn spec ->
      Enum.each(@files_env_keys, &System.delete_env/1)
      System.put_env("ANKOLE_FILES_STORE", spec.scheme)

      spec
      |> Map.delete(:scheme)
      |> Enum.each(fn {field, value} ->
        name =
          "ANKOLE_FILES_#{String.upcase(spec.scheme)}_#{field |> to_string() |> String.upcase()}"

        System.put_env(name, value)
      end)

      assert Bootstrap.files_store_spec() == spec
      assert {:ok, _store} = Ankole.Kernel.ObjectStore.open(spec)
    end)
  end

  test "preserves fs and s3 configuration and omits blank optional fields" do
    assert Bootstrap.files_store_spec() == nil
    System.put_env("ANKOLE_FILES_STORE", "fs")
    System.put_env("ANKOLE_FILES_FS_ROOT", "/tmp/files")
    assert Bootstrap.files_store_spec() == %{scheme: "fs", root: "/tmp/files"}

    System.put_env("ANKOLE_FILES_STORE", "s3")
    System.put_env("ANKOLE_FILES_S3_BUCKET", "files")
    System.put_env("ANKOLE_FILES_S3_REGION", "auto")
    System.put_env("ANKOLE_FILES_S3_ENDPOINT", "")
    assert Bootstrap.files_store_spec() == %{scheme: "s3", bucket: "files", region: "auto"}
  end

  test "rejects unknown backends and missing or blank required storage fields" do
    System.put_env("ANKOLE_FILES_STORE", "unknown")
    assert_raise RuntimeError, ~r/invalid ANKOLE_FILES_STORE/, &Bootstrap.files_store_spec/0

    System.put_env("ANKOLE_FILES_STORE", "azblob")

    assert_raise RuntimeError,
                 ~r/ANKOLE_FILES_AZBLOB_CONTAINER is required/,
                 &Bootstrap.files_store_spec/0

    System.put_env("ANKOLE_FILES_AZBLOB_CONTAINER", "")

    assert_raise RuntimeError,
                 ~r/ANKOLE_FILES_AZBLOB_CONTAINER is required/,
                 &Bootstrap.files_store_spec/0
  end

  defp tmp_root do
    root = Path.join(System.tmp_dir!(), "ankole-bootstrap-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    root
  end
end
