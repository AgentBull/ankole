defmodule Ankole.Plugins.Hook do
  @moduledoc "Calls domain transaction hooks from the site's active Plugin snapshot."

  @callback before_commit_in_tx(atom(), map()) :: :ok | {:error, term()}

  @doc "Returns the domain transaction hook points supported by the host."
  def points, do: [:create_agent, :create_invitation, :enable_signal_binding]

  def before_commit_in_tx(point, payload) do
    :ok = Ankole.Repo.require_transaction()

    Enum.reduce_while(Ankole.Plugins.Registry.hooks(point), :ok, fn module, :ok ->
      case module.before_commit_in_tx(point, payload) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end
end
