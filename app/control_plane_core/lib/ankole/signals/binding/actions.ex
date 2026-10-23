defmodule Ankole.Signals.Binding.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.Signals.Binding`.
  """
  use Ash.Resource.Actions.Implementation

  alias Ankole.Signals.Binding
  alias Ankole.Signals.Bindings

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:assign, input, _context),
    do: Ankole.Errors.wrap(Bindings.assign_in_tx(Ankole.Repo, input.arguments.assignment))

  defp action(:reassign, input, _context),
    do: Ankole.Errors.wrap(Bindings.reassign_in_tx(Ankole.Repo, input.arguments.assignment))

  defp action(:put_cloud, input, _context),
    do: Ankole.Errors.wrap(Bindings.put_cloud_binding_in_tx(Ankole.Repo, input.arguments.binding))

  defp action(:move_cloud, input, _context) do
    args = input.arguments

    Ankole.Errors.wrap(
      Bindings.move_cloud_binding_in_tx(
        Ankole.Repo,
        args.source,
        args.current_config,
        args.binding
      )
    )
  end

  defp action(:console_disable, input, _context) do
    args = input.arguments

    Ankole.Repo
    |> Bindings.disable_binding_in_tx(args.agent_uid, args.name)
    |> Ankole.Errors.not_found([:agent_not_found, :binding_not_found], Binding)
    |> Ankole.Errors.wrap()
  end

  defp action(:disable_by_name, input, _context) do
    args = input.arguments
    Ankole.Errors.wrap(Bindings.disable_binding_in_tx(Ankole.Repo, args.agent_uid, args.name))
  end
end
