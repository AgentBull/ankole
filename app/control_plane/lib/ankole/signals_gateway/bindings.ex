defmodule Ankole.SignalsGateway.Bindings do
  @moduledoc false

  alias Ankole.Repo
  alias Ankole.SignalsGateway.SignalBinding
  alias Ankole.SignalsGateway.Utils

  @spec upsert_binding(map()) :: {:ok, SignalBinding.t()} | {:error, term()}
  def upsert_binding(attrs) when is_map(attrs) do
    %SignalBinding{}
    |> SignalBinding.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:inserted_at]},
      conflict_target: [:agent_uid, :name],
      returning: true
    )
  end

  @spec get_binding(String.t(), String.t()) :: {:ok, SignalBinding.t()} | {:error, term()}
  def get_binding(agent_uid, binding_name) do
    case Repo.get_by(SignalBinding, agent_uid: Utils.normalize_uid(agent_uid), name: binding_name) do
      %SignalBinding{enabled: true, unavailable_reason: reason} when is_binary(reason) ->
        {:error, {:binding_unavailable, reason}}

      %SignalBinding{enabled: true} = binding ->
        {:ok, binding}

      %SignalBinding{enabled: false} ->
        {:error, :binding_disabled}

      nil ->
        {:error, :binding_not_found}
    end
  end
end
