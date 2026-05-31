defmodule BullxTelegram.SourceSetupTest do
  use BullX.DataCase, async: false

  alias BullX.Config.AppConfig
  alias BullX.Repo
  alias BullxTelegram.SourceSetup

  @sources_key "bullx.plugins.bullx_telegram.im_gateway_sources"

  setup do
    cache_pid = GenServer.whereis(BullX.Config.Cache)
    Ecto.Adapters.SQL.Sandbox.allow(BullX.Repo, self(), cache_pid)

    on_exit(fn ->
      BullX.Config.Cache.delete_raw(@sources_key)
      _ = BullxTelegram.SourceSupervisor.reconcile_sources()
    end)

    :ok
  end

  test "declares setup schema for an IM channel source" do
    assert SourceSetup.config_keys() == %{sources: @sources_key}
    assert [] = SourceSetup.generated_secret_fields()

    schema = SourceSetup.form_schema()
    assert schema.adapter_id == "telegram"
    assert schema.channel_kind == "im"
    refute Map.has_key?(schema, :source_id_label)
    refute Map.has_key?(schema.default_source, "id")
    refute Map.has_key?(schema.default_source, "start_transport")
    assert schema.default_source["group_message_mode"] == "engage_all"
    assert schema_field?(schema, ["source", "bot_token"])
    refute schema_field?(schema, ["source", "bot_username"])
    refute schema_field?(schema, ["source", "start_transport"])
  end

  test "casts one Telegram channel instance with its source-local bot token" do
    assert {:ok, source} =
             SourceSetup.cast_source(
               %{
                 "source" => %{
                   "id" => "bullx_bot",
                   "bot_token" => "123456:ABC",
                   "group_message_mode" => "engage_all",
                   "start_transport" => false
                 }
               },
               %{}
             )

    assert source["id"] == "bullx_bot"
    refute Map.has_key?(source, "bot_username")
    assert source["bot_token"] == "123456:ABC"
    assert source["group_message_mode"] == "engage_all"
    refute Map.has_key?(source, "start_transport")
  end

  test "requires source id" do
    assert {:error, %{field: "id"}} =
             SourceSetup.cast_source(
               %{
                 "source" => %{
                   "bot_token" => "123456:ABC"
                 }
               },
               %{}
             )
  end

  test "public projection redacts saved source token" do
    assert :ok =
             BullX.Config.put(
               @sources_key,
               Jason.encode!([
                 %{
                   "id" => "bullx_bot",
                   "bot_username" => "bullx_bot",
                   "bot_token" => "123456:ABC",
                   "enabled" => true
                 }
               ])
             )

    projection = SourceSetup.public_projection()

    assert [source] = projection.sources
    assert source["id"] == "bullx_bot"
    assert source["bot_username"] == "bullx_bot"
    assert source["bot_token"] == %{"present" => true, "masked" => "******"}

    stored_sources = Repo.get!(AppConfig, @sources_key)
    refute stored_sources.value =~ "123456:ABC"
  end

  test "reconcile restarts an existing runtime child when source config changes" do
    source = %{
      "id" => "bullx_bot",
      "bot_token" => "123456:ABC",
      "enabled" => true,
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

  defp runtime_child_pid!(source_id) do
    BullxTelegram.SourceSupervisor
    |> Process.whereis()
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {{BullxTelegram.SourceRuntime, ^source_id, _fingerprint}, pid, _type, _modules}
      when is_pid(pid) ->
        pid

      {{BullxTelegram.SourceRuntime, ^source_id}, pid, _type, _modules} when is_pid(pid) ->
        pid

      _child ->
        nil
    end)
    |> case do
      nil -> flunk("Telegram runtime child #{inspect(source_id)} was not running")
      pid -> pid
    end
  end

  defp schema_field?(schema, path) do
    schema.sections
    |> Enum.flat_map(& &1.fields)
    |> Enum.any?(&(&1.path == path))
  end
end
