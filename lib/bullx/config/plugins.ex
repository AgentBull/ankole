defmodule BullX.Config.Plugins do
  @moduledoc """
  Runtime configuration consumed by the plugin host.
  """

  use BullX.Config

  @first_party_default_plugins ["feishu", "bullx_telegram"]

  @envdoc false
  bullx_env(:configured_enabled_plugins,
    key: :enabled_plugins,
    type: BullX.Config.StringList,
    default: nil
  )

  @spec enabled_plugins!() :: [String.t()]
  def enabled_plugins! do
    case configured_enabled_plugins!() do
      nil -> @first_party_default_plugins
      plugins -> plugins
    end
    |> with_internal_plugins()
  end

  defp with_internal_plugins(plugins), do: Enum.uniq(plugins ++ internal_plugin_ids())

  defp internal_plugin_ids do
    :bullx
    |> Application.get_env(:internal_plugin_apps, [])
    |> Enum.map(&Atom.to_string/1)
  end
end
