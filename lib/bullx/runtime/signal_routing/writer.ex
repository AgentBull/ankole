defmodule BullX.Runtime.SignalRouting.Writer do
  @moduledoc false

  import Ecto.Changeset
  import Ecto.Query

  alias BullX.Repo
  alias BullX.Runtime.SignalRouting
  alias BullX.Runtime.SignalRouting.{Cache, Rule}

  @spec create_rule(map()) :: {:ok, Rule.t()} | {:error, Ecto.Changeset.t()}
  def create_rule(attrs) when is_map(attrs) do
    %Rule{}
    |> Rule.changeset(attrs)
    |> validate_agent_destination()
    |> Repo.insert()
    |> refresh_after_write()
  end

  @spec update_rule(Rule.t() | Ecto.UUID.t() | String.t(), map()) ::
          {:ok, Rule.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def update_rule(rule_or_id, attrs) when is_map(attrs) do
    with %Rule{} = rule <- get_rule(rule_or_id) do
      rule
      |> Rule.changeset(attrs)
      |> validate_agent_destination()
      |> Repo.update()
      |> refresh_after_write()
    else
      nil -> {:error, :not_found}
    end
  end

  @spec delete_rule(Rule.t() | Ecto.UUID.t() | String.t()) ::
          {:ok, Rule.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def delete_rule(%Rule{} = rule) do
    rule
    |> Repo.delete()
    |> refresh_after_write()
  end

  def delete_rule(id_or_key) do
    with %Rule{} = rule <- get_rule(id_or_key) do
      delete_rule(rule)
    else
      nil -> {:error, :not_found}
    end
  end

  @spec get_rule(Rule.t() | Ecto.UUID.t() | String.t()) :: Rule.t() | nil
  def get_rule(%Rule{} = rule), do: rule

  def get_rule(id_or_key) when is_binary(id_or_key) do
    case Ecto.UUID.cast(id_or_key) do
      {:ok, uuid} -> Repo.get(Rule, uuid)
      :error -> Repo.one(from rule in Rule, where: rule.key == ^id_or_key)
    end
  end

  def get_rule(_id_or_key), do: nil

  defp validate_agent_destination(%Ecto.Changeset{} = changeset) do
    case {changeset.valid?, get_field(changeset, :route_action),
          get_field(changeset, :agent_principal_id)} do
      {true, :deliver_agent, agent_principal_id} ->
        validate_active_agent(changeset, agent_principal_id)

      _other ->
        changeset
    end
  end

  defp validate_active_agent(changeset, agent_principal_id) do
    case SignalRouting.agent_destination_active?(agent_principal_id) do
      true ->
        changeset

      false ->
        add_error(changeset, :agent_principal_id, "must reference an active Agent Principal")
    end
  end

  defp refresh_after_write({:ok, %Rule{} = rule}) do
    case Cache.refresh_all() do
      :ok ->
        {:ok, rule}

      {:error, reason} ->
        :telemetry.execute(
          [:bullx, :runtime, :signal_routing, :cache, :refresh, :failed],
          %{count: 1},
          %{reason: reason}
        )

        {:ok, rule}
    end
  end

  defp refresh_after_write({:error, reason}), do: {:error, reason}
end
