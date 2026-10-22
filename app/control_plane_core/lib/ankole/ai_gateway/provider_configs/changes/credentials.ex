defmodule Ankole.AIGateway.ProviderConfigs.Changes.Credentials do
  @moduledoc false
  use Ash.Resource.Change

  alias Ankole.AIGateway.ProviderConfigs.Credentials

  @impl true
  def change(changeset, opts, _context) do
    case pool(changeset, opts[:operation]) do
      {:ok, :unchanged} ->
        Ash.Changeset.set_result(changeset, {:ok, changeset.data})

      {:ok, pool} ->
        Ash.Changeset.force_change_attribute(changeset, :credential_pool, pool)

      {:error, reason} ->
        Ash.Changeset.add_error(changeset, Ankole.Ash.DomainError.exception(reason: reason))
    end
  end

  defp pool(changeset, :add) do
    with {:ok, pool, _id} <-
           Credentials.append_credential(
             changeset.data,
             Ash.Changeset.get_argument(changeset, :input)
           ),
         do: {:ok, pool}
  end

  defp pool(changeset, :replace),
    do:
      Credentials.replace_credential(
        changeset.data,
        Ash.Changeset.get_argument(changeset, :credential_id),
        Ash.Changeset.get_argument(changeset, :input)
      )

  defp pool(changeset, :remove),
    do:
      Credentials.drop_credential(
        changeset.data,
        Ash.Changeset.get_argument(changeset, :credential_id)
      )

  defp pool(changeset, :strategy),
    do:
      Credentials.select_strategy(
        changeset.data,
        Ash.Changeset.get_argument(changeset, :strategy)
      )

  defp pool(changeset, :refresh),
    do:
      Credentials.refresh_credential(
        changeset.data,
        Ash.Changeset.get_argument(changeset, :credential_id),
        Ash.Changeset.get_argument(changeset, :credential)
      )

  defp pool(changeset, :cooldown),
    do:
      Credentials.cooldown(
        changeset.data,
        Ash.Changeset.get_argument(changeset, :credential),
        Ash.Changeset.get_argument(changeset, :until),
        Ash.Changeset.get_argument(changeset, :reason)
      )
end
