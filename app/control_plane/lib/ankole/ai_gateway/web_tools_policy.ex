defmodule Ankole.AIGateway.WebToolsPolicy do
  @moduledoc """
  AppConfigure-backed URL access policy for model-facing web tools.

  Ankole's digital-employee positioning treats intranet access as expected, so
  `web_tools.block_private_network` defaults to `false` and private-network
  URLs are allowed. When an operator enables it, model-supplied `web_fetch` and
  browser navigation URLs must point at public hosts. Cloud metadata endpoints
  are rejected regardless of this setting.
  """

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Definition
  alias Ankole.AppConfigure.Schema

  @block_private_network_key "web_tools.block_private_network"

  @doc """
  Returns the scoped AppConfigure definition for the private-network block.
  """
  @spec block_private_network_definition() :: Definition.t()
  def block_private_network_definition do
    AppConfigure.define(
      key: @block_private_network_key,
      scope: :scoped,
      encrypted: false,
      schema: Schema.boolean(),
      default_value: false,
      description:
        "When true, model-supplied web_fetch and browser navigation URLs are rejected unless they point at public hosts: literal localhost, loopback, private, link-local, and CGNAT addresses are blocked. Cloud metadata endpoints are always rejected regardless of this setting."
    )
  end

  @doc """
  Registers the web tools policy definitions.
  """
  @spec ensure_registered() :: :ok | {:error, term()}
  def ensure_registered do
    case AppConfigure.register_definitions([block_private_network_definition()]) do
      :ok -> :ok
      {:error, {:duplicate_key, @block_private_network_key}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Resolves whether private-network URLs are blocked for an agent.

  A resolution failure is a storage error, not a policy answer, so it is
  returned instead of silently falling back to the open default.
  """
  @spec block_private_network?(String.t()) :: {:ok, boolean()} | {:error, term()}
  def block_private_network?(agent_uid) when is_binary(agent_uid) do
    with :ok <- ensure_registered(),
         {:ok, resolution} <-
           AppConfigure.resolve(block_private_network_definition(), agent_id: agent_uid) do
      {:ok, resolution.value == true}
    else
      :error -> {:error, :web_tools_policy_unresolved}
      {:error, reason} -> {:error, reason}
    end
  end
end
