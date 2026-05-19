defmodule Feishu.SourceSetupTest do
  use BullX.DataCase, async: false

  alias BullX.Config.AppConfig
  alias BullX.Repo
  alias Feishu.SourceSetup

  @credentials_key "bullx.plugins.feishu.credentials"
  @sources_key "bullx.plugins.feishu.eventbus_sources"

  setup do
    cache_pid = GenServer.whereis(BullX.Config.Cache)
    Ecto.Adapters.SQL.Sandbox.allow(BullX.Repo, self(), cache_pid)

    on_exit(fn ->
      BullX.Config.Cache.delete_raw(@credentials_key)
      BullX.Config.Cache.delete_raw(@sources_key)
      _ = Feishu.SourceSupervisor.reconcile_sources()
    end)

    :ok
  end

  test "declares the setup config keys and generated-secret fields" do
    assert SourceSetup.config_keys() == %{credentials: @credentials_key, sources: @sources_key}
    assert [["credentials", "verification_token"]] = SourceSetup.generated_secret_fields()

    schema = SourceSetup.form_schema()
    assert schema.adapter_id == "feishu"
    assert Enum.any?(schema.sections, &(&1.key == "credentials"))
    assert schema.default_source["oidc"]["enabled"] == true
    assert schema_field?(schema, ["source", "oidc", "enabled"])
  end

  test "casts credentials and source config without putting secrets in source config" do
    payload = source_payload()

    assert {:ok, credentials} = SourceSetup.cast_credentials(payload)
    assert credentials["default"]["app_id"] == "cli_setup"
    assert credentials["default"]["app_secret"] == "app_secret"
    assert credentials["default"]["verification_token"] == "verify_token"

    assert {:ok, source} = SourceSetup.cast_source(payload, credentials)
    assert source["id"] == "main"
    assert source["credential_id"] == "default"
    assert source["start_transport"] == false

    assert source["oidc"] == %{
             "enabled" => true,
             "redirect_uri" => "https://bullx.example.com/sessions/oidc/main/callback"
           }

    refute Map.has_key?(source, "app_secret")
    refute Map.has_key?(source, "verification_token")
    refute inspect(source) =~ "app_secret"
  end

  test "public projection redacts saved credentials and reports runtime readiness" do
    assert :ok =
             BullX.Config.put_many(%{
               @credentials_key =>
                 Jason.encode!(%{
                   "default" => %{
                     "app_id" => "cli_setup",
                     "app_secret" => "app_secret",
                     "verification_token" => "verify_token"
                   }
                 }),
               @sources_key =>
                 Jason.encode!([
                   %{
                     "id" => "main",
                     "credential_id" => "default",
                     "enabled" => true,
                     "domain" => "feishu",
                     "im_listen_mode" => "addressed_only",
                     "start_transport" => false
                   }
                 ])
             })

    assert {:ok, %{sources: [%{id: "main", ready: true}]}} =
             SourceSetup.reconcile_sources()

    projection = SourceSetup.public_projection()

    assert projection.credentials["default"]["app_id"] == "cli_setup"

    assert projection.credentials["default"]["app_secret"] == %{
             "present" => true,
             "masked" => "******"
           }

    assert [source] = projection.sources
    assert source["id"] == "main"
    assert source["runtime"].ready == true

    stored_credentials = Repo.get!(AppConfig, @credentials_key)
    refute stored_credentials.value =~ "app_secret"
  end

  defp source_payload do
    %{
      "credentials" => %{
        "credential_id" => "default",
        "app_id" => "cli_setup",
        "app_secret" => "app_secret",
        "verification_token" => "verify_token"
      },
      "source" => %{
        "id" => "main",
        "credential_id" => "default",
        "enabled" => true,
        "domain" => "feishu",
        "oidc" => %{
          "enabled" => true,
          "redirect_uri" => "https://bullx.example.com/sessions/oidc/main/callback"
        },
        "im_listen_mode" => "addressed_only",
        "start_transport" => false
      }
    }
  end

  defp schema_field?(schema, path) do
    schema.sections
    |> Enum.flat_map(& &1.fields)
    |> Enum.any?(&(&1.path == path))
  end
end
