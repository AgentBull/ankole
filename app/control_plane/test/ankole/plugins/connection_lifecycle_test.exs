defmodule Ankole.Plugins.ConnectionLifecycleTest do
  use ExUnit.Case, async: true

  alias Ankole.Plugins.ConnectionLifecycle

  test "runs on startup and on an explicit reconcile" do
    parent = self()
    name = unique_name()

    start_supervised!(%{
      id: name,
      start:
        {ConnectionLifecycle, :start_link,
         [
           [name: name, interval_ms: nil],
           [
             name: name,
             default_interval_ms: 60_000,
             reconcile_opts: :adapter_options,
             reconcile: fn opts ->
               send(parent, {:reconciled, opts})
               %{errors: []}
             end
           ]
         ]}
    })

    assert_receive {:reconciled, :adapter_options}
    assert %{errors: []} = ConnectionLifecycle.reconcile(name)
    assert_receive {:reconciled, :adapter_options}

    assert :ok = ConnectionLifecycle.reconcile_async(name)
    assert_receive {:reconciled, :adapter_options}
  end

  test "stops only registered keys outside the desired set" do
    parent = self()

    assert 1 ==
             ConnectionLifecycle.stop_undesired(
               ConnectionLifecycle.desired_snapshot(%{:desired => %{}}, []),
               [:desired, :zombie],
               fn key ->
                 send(parent, {:stopped, key})
                 :ok
               end
             )

    assert_receive {:stopped, :zombie}
    refute_receive {:stopped, :desired}
  end

  test "keeps registered keys when the desired snapshot is incomplete" do
    parent = self()

    assert 0 ==
             ConnectionLifecycle.stop_undesired(
               ConnectionLifecycle.desired_snapshot(%{}, [:config_unavailable]),
               [:live],
               fn key ->
                 send(parent, {:stopped, key})
                 :ok
               end
             )

    refute_receive {:stopped, :live}
  end

  defp unique_name do
    {:global, {__MODULE__, make_ref()}}
  end
end
