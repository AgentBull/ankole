defmodule Ankole.Brain.Schemas.Object.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.Brain.Schemas.Object`.
  """
  use Ash.Resource.Actions.Implementation

  alias Ankole.Brain.Schemas.Object

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:fork_library_page, %{arguments: args}, _context) do
    Ankole.Brain.Console.result(
      Ankole.Brain.Objects.fork_library_page_in_tx(args.slug),
      Object
    )
  end

  defp action(:restore_object, %{arguments: args}, _context),
    do:
      Ankole.Brain.Console.result(
        Ankole.Brain.Objects.restore_in_tx(args.slug),
        Object
      )

  defp action(:console_create, %{arguments: args}, context) do
    args
    |> Map.take([:slug, :type, :subtype, :title, :body, :meta, :effective_date, :tags])
    |> Ankole.Brain.Objects.create_object_in_tx(Ankole.Brain.Console.writer(context))
    |> Ankole.Brain.Console.result(Object)
  end

  defp action(:console_update, %{arguments: args}, context) do
    attrs =
      Map.take(args, [:expected_content_hash, :subtype, :title, :body, :meta, :effective_date])

    attrs = if args[:tags], do: Map.put(attrs, :tags, args.tags), else: attrs

    args.slug
    |> Ankole.Brain.Objects.update_object_in_tx(
      attrs,
      Ankole.Brain.Console.writer(context),
      author: Ankole.Brain.Console.actor_ref(context)
    )
    |> Ankole.Brain.Console.result(Object)
  end

  defp action(:console_rollback, %{arguments: args}, context) do
    args.slug
    |> Ankole.Brain.Objects.rollback_in_tx(
      args.version_id,
      Ankole.Brain.Console.writer(context),
      author: Ankole.Brain.Console.actor_ref(context)
    )
    |> Ankole.Brain.Console.result(Object)
  end

  defp action(:console_forget, %{arguments: args}, _context) do
    args.slug
    |> Ankole.Brain.Forget.forget_object_in_tx(args[:reason] || "", :admin)
    |> Ankole.Brain.Console.result(Object)
  end
end
