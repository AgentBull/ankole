defmodule Feishu.SourceSetupTest do
  use BullX.DataCase, async: false

  alias BullX.Config.AppConfig
  alias BullX.Repo
  alias Feishu.SourceSetup

  @sources_key "bullx.plugins.feishu.im_gateway_sources"

  setup do
    cache_pid = GenServer.whereis(BullX.Config.Cache)
    Ecto.Adapters.SQL.Sandbox.allow(BullX.Repo, self(), cache_pid)

    on_exit(fn ->
      BullX.Config.Cache.delete_raw(@sources_key)
      _ = Feishu.SourceSupervisor.reconcile_sources()
    end)

    :ok
  end

  test "declares the setup config keys and generated-secret fields" do
    assert SourceSetup.config_keys() == %{sources: @sources_key}
    assert [] = SourceSetup.generated_secret_fields()

    schema = SourceSetup.form_schema()
    assert schema.adapter_id == "feishu"
    assert schema.channel_kind == "im"
    refute Map.has_key?(schema, :source_id_label)
    refute Map.has_key?(schema.default_source, "id")
    refute Map.has_key?(schema.default_source, "start_transport")
    assert schema.default_source["im_listen_mode"] == "all_messages"
    assert schema.default_source["oidc"]["enabled"] == true
    assert schema_field?(schema, ["source", "oidc", "enabled"])
    assert schema_field?(schema, ["source", "oidc", "callback_url"])
    refute schema_field?(schema, ["source", "oidc", "redirect_uri"])
    assert schema_field?(schema, ["source", "app_id"])
    assert schema_field?(schema, ["source", "app_secret"])
    refute schema_field?(schema, ["source", "start_transport"])
  end

  test "casts one channel instance with its source-local app secret" do
    payload = source_payload()

    assert {:ok, source} = SourceSetup.cast_source(payload, %{})
    assert source["id"] == "main"
    assert source["app_id"] == "cli_setup"
    assert source["app_secret"] == "app_secret"
    assert source["im_listen_mode"] == "all_messages"
    refute Map.has_key?(source, "start_transport")

    assert source["oidc"] == %{"enabled" => true}
  end

  test "requires source id" do
    assert {:error, %{field: "id"}} =
             SourceSetup.cast_source(
               %{
                 "source" => %{
                   "app_id" => "cli_setup",
                   "app_secret" => "app_secret"
                 }
               },
               %{}
             )
  end

  test "public projection redacts saved source secrets and reports runtime readiness" do
    assert :ok =
             BullX.Config.put(
               @sources_key,
               Jason.encode!([
                 %{
                   "id" => "main",
                   "app_id" => "cli_setup",
                   "app_secret" => "app_secret",
                   "enabled" => true,
                   "domain" => "feishu",
                   "im_listen_mode" => "addressed_only"
                 }
               ])
             )

    projection = SourceSetup.public_projection()

    assert [source] = projection.sources
    assert source["id"] == "main"
    assert source["app_id"] == "cli_setup"
    assert source["app_secret"] == %{"present" => true, "masked" => "******"}
    assert source["runtime"]["ready"] == false or source["runtime"].ready == false

    stored_sources = Repo.get!(AppConfig, @sources_key)
    refute stored_sources.value =~ "app_secret"
  end

  defp source_payload do
    %{
      "source" => %{
        "id" => "main",
        "app_id" => "cli_setup",
        "app_secret" => "app_secret",
        "enabled" => true,
        "domain" => "feishu",
        "oidc" => %{"enabled" => true},
        "im_listen_mode" => "all_messages",
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
