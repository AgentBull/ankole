defmodule Ankole.SignalsGateway.GroupMessageModes do
  @moduledoc """
  Shared IM group-message modes exposed by SignalsGateway adapters.
  """

  @default_mode "addressed_only"

  @modes [
    %{
      value: "addressed_only",
      policy: :ignore,
      label: %{
        "default" => "Addressed messages only",
        "zh-Hans-CN" => "仅处理明确提及"
      },
      description: %{
        "default" => "Ignore unaddressed group messages.",
        "zh-Hans-CN" => "忽略群聊中未明确发给当前智能体的消息。"
      }
    },
    %{
      value: "observe_all",
      policy: :record_only,
      label: %{
        "default" => "Observe unaddressed messages",
        "zh-Hans-CN" => "记录未提及消息"
      },
      description: %{
        "default" =>
          "Mirror unaddressed group messages for context without starting an actor turn.",
        "zh-Hans-CN" => "记录群聊中未提及的消息作为上下文，但不启动智能体回合。"
      }
    },
    %{
      value: "may_intervene",
      policy: :may_intervene,
      label: %{
        "default" => "May intervene",
        "zh-Hans-CN" => "可主动介入"
      },
      description: %{
        "default" => "Let the agent consider intervening in unaddressed group messages.",
        "zh-Hans-CN" => "允许智能体判断是否介入未明确提及它的群聊消息。"
      }
    }
  ]

  @doc """
  Returns the default group-message mode.
  """
  @spec default_mode() :: String.t()
  def default_mode, do: @default_mode

  @doc """
  Returns the durable SignalsGateway binding policy for a group-message mode.
  """
  @spec policy(String.t()) ::
          {:ok, :ignore | :record_only | :may_intervene} | {:error, term()}
  def policy(mode) when is_binary(mode) do
    case Enum.find(@modes, &(&1.value == mode)) do
      %{policy: policy} -> {:ok, policy}
      nil -> {:error, {:unknown_group_message_mode, mode}}
    end
  end

  def policy(mode), do: {:error, {:unknown_group_message_mode, mode}}

  @doc """
  Returns the setup/console field for the adapter-supported mode subset.
  """
  @spec field([String.t()] | nil) :: map()
  def field(supported_values \\ nil) do
    options = options(supported_values)

    %{
      path: "group_message_mode",
      label: %{
        "default" => "Group message mode",
        "zh-Hans-CN" => "群聊消息模式"
      },
      description: %{
        "default" =>
          "Controls how the agent handles group messages that do not explicitly address it.",
        "zh-Hans-CN" => "控制智能体如何处理群聊中未明确发给它的消息。"
      },
      type: "select",
      required: true,
      advanced: false,
      default: default_for(options),
      options: options
    }
  end

  @doc """
  Returns UI-ready mode option maps for a supported subset.
  """
  @spec options([String.t()] | nil) :: [map()]
  def options(nil), do: options(Enum.map(@modes, & &1.value))

  def options(values) when is_list(values) do
    values
    |> Enum.flat_map(fn value ->
      case Enum.find(@modes, &(&1.value == value)) do
        nil -> []
        mode -> [Map.take(mode, [:value, :label, :description])]
      end
    end)
  end

  defp default_for(options) do
    case Enum.any?(options, &(&1.value == @default_mode)) do
      true -> @default_mode
      false -> options |> List.first(%{value: @default_mode}) |> Map.fetch!(:value)
    end
  end
end
