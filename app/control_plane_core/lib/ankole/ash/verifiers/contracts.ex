defmodule Ankole.Ash.Verifiers.Contracts do
  @moduledoc false
  use Spark.Dsl.Transformer
  alias Spark.Dsl.Verifier

  @transaction_hooks [
    Ash.Resource.Change.BeforeTransaction,
    Ash.Resource.Change.AfterTransaction,
    Ash.Resource.Change.AroundTransaction
  ]
  @action_hooks [Ash.Resource.Change.BeforeAction, Ash.Resource.Change.AfterAction]

  def after?(module),
    do:
      module in [
        Ash.Resource.Transformers.DefaultAccept,
        Ash.Resource.Transformers.SetPrimaryActions,
        AshStateMachine.Transformers.AddState,
        Ankole.Ash.Transformers.TenantUpsertCondition
      ]

  def transform(dsl) do
    case verify(dsl) do
      :ok -> {:ok, dsl}
      error -> error
    end
  end

  def verify(dsl) do
    actions = Ash.Resource.Info.actions(dsl)
    tenant? = Verifier.get_persisted(dsl, :ankole_tenancy) == :tenant

    cond do
      AshPostgres.DataLayer.Info.migrate?(dsl) ->
        error(dsl, [:postgres], "existing tables must retain Ecto migrations with migrate? false")

      Ash.Resource.Info.authorizers(dsl) != [] or Verifier.get_entities(dsl, [:policies]) != [] ->
        error(dsl, [], "Principal/AuthZ owns authorization; resource policies are forbidden")

      tenant? and Ash.Resource.Info.multitenancy_global?(dsl) ->
        error(dsl, [:multitenancy], "tenant resources cannot enable global?")

      tenant? and Ash.Resource.Info.attribute(dsl, :tenant_id).writable? ->
        error(dsl, [:attributes, :tenant_id], "tenant_id must not be writable")

      true ->
        Enum.reduce_while(actions, :ok, fn action, :ok ->
          case verify_action(dsl, action, tenant?) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
        end)
    end
  end

  defp verify_action(dsl, action, tenant?) do
    changes = Map.get(action, :changes, []) ++ Ash.Resource.Info.changes(dsl, action.type)
    modules = for %Ash.Resource.Change{change: {module, _opts}} <- changes, do: module

    validations =
      if Map.get(action, :skip_global_validations?, false),
        do: changes,
        else: changes ++ Ash.Resource.Info.validations(dsl, action.type)

    deferred_validation? =
      Enum.any?(validations, fn
        %Ash.Resource.Validation{before_action?: true} -> true
        _entity -> false
      end)

    with :ok <- verify_action_tenancy(dsl, action, tenant?),
         :ok <- verify_action_transaction(dsl, action, modules, deferred_validation?) do
      verify_action_upsert(dsl, action, modules, tenant?)
    end
  end

  defp verify_action_tenancy(dsl, action, tenant?) do
    cond do
      tenant? and :tenant_id in List.wrap(Map.get(action, :accept)) ->
        error(dsl, [:actions, action.name], "actions must not accept tenant_id")

      Map.get(action, :multitenancy, :enforce) in [:bypass, :bypass_all] ->
        error(dsl, [:actions, action.name], "tenant actions must retain multitenancy enforcement")

      action.type != :read and Map.get(action, :multitenancy, :enforce) == :allow_global ->
        error(dsl, [:actions, action.name], "global actions must be reads")

      true ->
        :ok
    end
  end

  defp verify_action_transaction(dsl, action, modules, deferred_validation?) do
    in_tx? = Ankole.Ash.RequireTransaction in modules
    atomic_in_tx? = Ankole.Ash.RequireTransaction.Atomic in modules
    caller_transaction? = in_tx? or atomic_in_tx?

    cond do
      Enum.any?(modules, &(&1 in @transaction_hooks)) ->
        error(dsl, [:actions, action.name], "transaction hooks are forbidden")

      caller_transaction? and action.transaction? ->
        error(dsl, [:actions, action.name], "caller-owned actions require transaction? false")

      atomic_in_tx? and not Map.get(action, :require_atomic?, false) ->
        error(dsl, [:actions, action.name], "atomic in_tx actions require require_atomic? true")

      in_tx? and action.type in [:update, :destroy] and
          (Map.get(action, :require_atomic?, false) or Map.get(action, :atomic_upgrade?, false)) ->
        error(
          dsl,
          [:actions, action.name],
          "in_tx updates require transaction?, require_atomic?, and atomic_upgrade? false"
        )

      caller_transaction? and Enum.any?(modules, &(&1 in @action_hooks)) ->
        error(
          dsl,
          [:actions, action.name],
          "in_tx updates must reject through changes or validations, not action hooks"
        )

      caller_transaction? and deferred_validation? ->
        error(
          dsl,
          [:actions, action.name],
          "in_tx validations must reject before action hooks; before_action? is forbidden"
        )

      true ->
        :ok
    end
  end

  defp verify_action_upsert(dsl, action, modules, true) do
    cond do
      Map.get(action, :upsert?, false) and
          (not is_list(action.upsert_fields) or
             :tenant_id in action.upsert_fields) ->
        error(
          dsl,
          [:actions, action.name],
          "upserts require explicit upsert_fields without tenant_id"
        )

      Map.get(action, :upsert?, false) and
          Enum.any?(modules, &(&1 in [Ash.Resource.Change.Atomic, Ash.Resource.Change.AtomicSet])) ->
        error(dsl, [:actions, action.name], "upserts must not use atomics")

      true ->
        :ok
    end
  end

  defp verify_action_upsert(_dsl, _action, _modules, false), do: :ok

  defp error(dsl, path, message),
    do:
      {:error,
       Spark.Error.DslError.exception(
         module: Verifier.get_persisted(dsl, :module),
         path: path,
         message: message
       )}
end
