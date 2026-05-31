defmodule Discord.SourceSetupTest do
  use BullX.DataCase, async: false

  alias BullX.Config.AppConfig
  alias BullX.Repo
  alias Discord.SourceSetup

  @sources_key "bullx.plugins.discord.im_gateway_sources"

  setup do
    cache_pid = GenServer.whereis(BullX.Config.Cache)
    Ecto.Adapters.SQL.Sandbox.allow(BullX.Repo, self(), cache_pid)
    ensure_source_supervisor()

    on_exit(fn ->
      BullX.Config.Cache.delete_raw(@sources_key)
      _ = Discord.SourceSupervisor.reconcile_sources()
    end)

    :ok
  end

  test "declares setup schema for an IM channel source" do
    assert SourceSetup.config_keys() == %{sources: @sources_key}
    assert [] = SourceSetup.generated_secret_fields()

    schema = SourceSetup.form_schema()
    assert schema.adapter_id == "discord"
    assert schema.channel_kind == "im"
    refute Map.has_key?(schema, :source_id_label)
    refute Map.has_key?(schema.default_source, "id")
    refute Map.has_key?(schema.default_source, "start_transport")
    assert schema.default_source["group_message_mode"] == "engage_all"
    assert schema_field?(schema, ["source", "application_id"])
    assert schema_field?(schema, ["source", "bot_token"])
    assert schema_field?(schema, ["source", "client_secret"])
    assert schema_field?(schema, ["source", "oauth2", "callback_url"])
    refute schema_field?(schema, ["source", "oauth2", "redirect_uri"])
    refute schema_field?(schema, ["source", "start_transport"])
  end

  test "casts one Discord channel instance with source-local secrets" do
    assert {:ok, source} =
             SourceSetup.cast_source(
               %{
                 "source" => %{
                   "id" => "bullx_bot",
                   "application_id" => "app_1",
                   "bot_token" => "bot_token",
                   "client_secret" => "client_secret",
                   "oauth2" => %{
                     "enabled" => true
                   },
                   "group_message_mode" => "engage_all",
                   "start_transport" => false
                 }
               },
               %{}
             )

    assert source["id"] == "bullx_bot"
    assert source["application_id"] == "app_1"
    assert source["bot_token"] == "bot_token"
    assert source["client_secret"] == "client_secret"
    assert source["oauth2"]["enabled"] == true
    assert source["group_message_mode"] == "engage_all"
    refute Map.has_key?(source["oauth2"], "redirect_uri")
    refute Map.has_key?(source, "start_transport")
  end

  test "requires source id" do
    assert {:error, %{field: "id"}} =
             SourceSetup.cast_source(
               %{
                 "source" => %{
                   "application_id" => "app_1",
                   "bot_token" => "bot_token"
                 }
               },
               %{}
             )
  end

  test "public projection redacts saved source secrets" do
    assert :ok =
             BullX.Config.put(
               @sources_key,
               Jason.encode!([
                 %{
                   "id" => "bullx_bot",
                   "application_id" => "app_1",
                   "bot_token" => "bot_token",
                   "client_secret" => "client_secret",
                   "enabled" => true,
                   "oauth2" => %{"enabled" => true}
                 }
               ])
             )

    projection = SourceSetup.public_projection()

    assert [source] = projection.sources
    assert source["id"] == "bullx_bot"
    assert source["application_id"] == "app_1"
    assert source["bot_token"] == %{"present" => true, "masked" => "******"}
    assert source["client_secret"] == %{"present" => true, "masked" => "******"}

    stored_sources = Repo.get!(AppConfig, @sources_key)
    refute stored_sources.value =~ "bot_token"
    refute stored_sources.value =~ "client_secret"
  end

  test "reconcile restarts an existing runtime child when source config changes" do
    source = %{
      "id" => "bullx_bot",
      "application_id" => "app_1",
      "bot_token" => "bot_token",
      "client_secret" => "client_secret",
      "enabled" => true,
      "oauth2" => %{"enabled" => true},
      "group_message_mode" => "addressed_only",
      "start_transport" => false
    }

    assert :ok = put_sources([source])
    assert {:ok, %{sources: [%{id: "bullx_bot", ready: true}]}} = SourceSetup.reconcile_sources()
    first_pid = runtime_child_pid!("bullx_bot")

    assert {:ok, %{sources: [%{id: "bullx_bot", ready: true}]}} = SourceSetup.reconcile_sources()
    assert runtime_child_pid!("bullx_bot") == first_pid

    assert :ok = put_sources([Map.put(source, "group_message_mode", "engage_all")])
    assert {:ok, %{sources: [%{id: "bullx_bot", ready: true}]}} = SourceSetup.reconcile_sources()
    refute runtime_child_pid!("bullx_bot") == first_pid
    refute Process.alive?(first_pid)
  end

  defp put_sources(sources), do: BullX.Config.put(@sources_key, Jason.encode!(sources))

  defp ensure_source_supervisor do
    case Process.whereis(Discord.SourceSupervisor) do
      nil -> start_supervised!(Discord.SourceSupervisor)
      _pid -> :ok
    end
  end

  defp runtime_child_pid!(source_id) do
    Discord.SourceSupervisor
    |> Process.whereis()
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {{Discord.SourceRuntime, ^source_id, _fingerprint}, pid, _type, _modules}
      when is_pid(pid) ->
        pid

      {{Discord.SourceRuntime, ^source_id}, pid, _type, _modules} when is_pid(pid) ->
        pid

      _child ->
        nil
    end)
    |> case do
      nil -> flunk("Discord runtime child #{inspect(source_id)} was not running")
      pid -> pid
    end
  end

  defp schema_field?(schema, path) do
    schema.sections
    |> Enum.flat_map(& &1.fields)
    |> Enum.any?(&(&1.path == path))
  end
end
