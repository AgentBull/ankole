defmodule Ankole.Plugins.Contracts do
  @moduledoc """
  The table of subsystem contracts that a Control Plane Plugin can declare.

  An adapter declaration names its `contract_id`. The subsystem that owns the
  contract supplies the functions of its entry in this table:

    * `validate` receives one declaration and returns `:ok` or
      `{:error, reason}`. The Registry calls it at startup for each active
      declaration.
    * `refresh` publishes the subsystem view of the boot snapshot. A function
      of arity 1 receives the active declarations of the contract. A function
      of arity 2 receives the discovered and the active Plugin specs.
    * `veto_disable` receives the previous enabled Plugin ids and the next
      enabled Plugin ids, inside the transaction that writes the enable list.
      It returns `:ok` or `{:error, reason}` to stop the write.

  `Ankole.Plugins.Registry` and `Ankole.Plugins.Config` use only this table. A
  new contract adds one entry here. A declaration of a contract without an
  entry keeps only the generic shape check of `Ankole.Plugins.Spec`.
  """

  @doc "Validates one adapter declaration against its contract."
  @spec validate(String.t() | nil, map()) :: :ok | {:error, term()}
  def validate(contract_id, declaration) do
    case contract(contract_id)[:validate] do
      nil -> :ok
      validate -> validate.(declaration)
    end
  end

  @doc "Publishes the boot snapshot to each subsystem that keeps a view of it."
  @spec refresh([Ankole.Plugins.Spec.t()], [Ankole.Plugins.Spec.t()]) :: :ok
  def refresh(discovered, active) do
    for {contract_id, %{refresh: refresh}} <- contracts() do
      case Function.info(refresh, :arity) do
        {:arity, 1} -> refresh.(declarations(active, contract_id))
        {:arity, 2} -> refresh.(discovered, active)
      end
    end

    :ok
  end

  @doc """
  Lets each contract stop a change of the enable list.

  The caller holds the transaction and the key lock of the enable list.
  """
  @spec veto_disable([String.t()], [String.t()]) :: :ok | {:error, term()}
  def veto_disable(previous_ids, enabled_ids) do
    Enum.reduce_while(contracts(), :ok, fn
      {_contract_id, %{veto_disable: veto}}, :ok ->
        case veto.(previous_ids, enabled_ids) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end

      _contract, :ok ->
        {:cont, :ok}
    end)
  end

  defp contract(contract_id), do: Map.get(contracts(), contract_id, %{})

  defp declarations(specs, contract_id) do
    for spec <- specs,
        %{contract_id: ^contract_id} = declaration <- spec.adapter_declarations,
        do: declaration
  end

  # The table is a function body, so the subsystem modules stay runtime
  # dependencies of this module.
  defp contracts do
    %{
      "signals.adapter" => %{validate: &Ankole.Signals.Adapters.validate_declaration/1},
      "signals.webhook_handler" => %{
        validate: &Ankole.Signals.WebhookHandlers.validate_declaration/1
      },
      "principals.identity_provider" => %{
        validate: &Ankole.IdentityProviders.validate_adapter_declaration/1,
        veto_disable: &Ankole.IdentityProviders.Config.veto_plugin_disable_in_tx/2
      },
      "ai_gateway.provider" => %{
        validate: &Ankole.AIGateway.Providers.validate_adapter_declaration/1,
        refresh: &Ankole.AIGateway.Providers.refresh_from_adapter_declarations/1
      },
      "agent_workers.provider_kind" => %{
        validate: &Ankole.AgentWorkers.ProviderKind.validate_adapter_declaration/1,
        refresh: &Ankole.AgentWorkers.ProviderKind.refresh_from_specs/2
      }
    }
  end
end
