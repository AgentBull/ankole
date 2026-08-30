defmodule Ankole.SignalsGateway.UnmatchedSenderPolicies do
  @moduledoc """
  Binding policies for signal senders that map to no Principal.
  """

  @default_value "manual_review"

  @policies [
    %{
      value: "manual_review",
      policy: :manual_review,
      label: %{
        "default" => "Manual review",
        "zh-Hans-CN" => "手动审核"
      },
      description: %{
        "default" =>
          "Hold the sender for manual binding in the console and tell them to contact an administrator.",
        "zh-Hans-CN" => "把发信人放入待绑定列表，并提示其联系管理员在后台绑定账号。"
      }
    },
    %{
      value: "create_standalone",
      policy: :create_standalone,
      label: %{
        "default" => "Create a standalone account",
        "zh-Hans-CN" => "自动创建独立账号"
      },
      description: %{
        "default" => "Create a standalone account for the sender and serve them right away.",
        "zh-Hans-CN" => "为发信人自动创建独立账号并立即提供服务。"
      }
    }
  ]

  @doc """
  Returns the default unmatched-sender policy value.
  """
  @spec default_value() :: String.t()
  def default_value, do: @default_value

  @doc """
  Returns the durable binding policy for a console value.
  """
  @spec policy(String.t()) :: {:ok, :manual_review | :create_standalone} | {:error, term()}
  def policy(value) when is_binary(value) do
    case Enum.find(@policies, &(&1.value == value)) do
      %{policy: policy} -> {:ok, policy}
      nil -> {:error, {:unknown_unmatched_sender_policy, value}}
    end
  end

  def policy(value), do: {:error, {:unknown_unmatched_sender_policy, value}}

  @doc """
  Returns the console value for a durable binding policy.
  """
  @spec value(:manual_review | :create_standalone) :: String.t()
  def value(policy) when is_atom(policy) do
    case Enum.find(@policies, &(&1.policy == policy)) do
      %{value: value} -> value
      nil -> @default_value
    end
  end

  @doc """
  Returns the setup/console select field for the policy.
  """
  @spec field() :: map()
  def field do
    %{
      path: "unmatched_sender_policy",
      label: %{
        "default" => "When account auto-mapping fails",
        "zh-Hans-CN" => "自动映射账号失败时"
      },
      description: %{
        "default" =>
          "What the agent does with a sender that maps to no known account: hold them for manual binding or create a standalone account.",
        "zh-Hans-CN" => "发信人无法映射到已知账号时的处置：等待管理员手动绑定，或自动创建独立账号。"
      },
      type: "select",
      required: true,
      advanced: false,
      default: @default_value,
      options:
        Enum.map(@policies, fn policy ->
          %{value: policy.value, label: policy.label, description: policy.description}
        end)
    }
  end
end
