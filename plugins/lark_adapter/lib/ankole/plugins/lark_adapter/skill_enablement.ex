defmodule Ankole.Plugins.LarkAdapter.SkillEnablement do
  @moduledoc """
  Projects the active Lark signal binding into the Library's bot-only CLI Skill
  execution profile.

  The plugin owns Lark configuration and compatibility policy. The Library
  owns the persisted/manual flag and how this result affects effective Skill
  visibility.
  """

  @behaviour Ankole.AIAgent.Library.SkillEnablementProvider

  alias Ankole.AIAgent.Library.SkillEnablementProvider.Context
  alias Ankole.AppConfigure
  alias Ankole.Plugins.LarkAdapter.Config
  alias Ankole.SignalsGateway.Binding
  alias Ankole.SignalsGateway.Bindings

  @impl true
  def resolve(%Context{agent_uid: agent_uid, repo: repo}) do
    definition = Config.auto_enable_lark_skills_definition()

    case AppConfigure.get(definition) do
      {:ok, true} -> resolve_automatic(agent_uid, repo)
      {:ok, false} -> {:ok, :manual}
      {:error, {:unknown_key, key}} when key == definition.key -> {:ok, {:projected, false}}
      :error -> {:ok, {:projected, false}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_automatic(agent_uid, repo) do
    with {:ok, bindings} <- Bindings.list_available_agent_bindings(agent_uid, repo: repo) do
      {:ok, {:projected, Enum.any?(bindings, &lark_cli_binding?/1)}}
    end
  end

  defp lark_cli_binding?(%Binding{adapter: "lark", config_ref: config_ref}) do
    case Config.load_chat_config_ref(config_ref) do
      {:ok, config} -> Config.lark_cli_compatible?(config)
      _error -> false
    end
  end

  defp lark_cli_binding?(_binding), do: false
end
