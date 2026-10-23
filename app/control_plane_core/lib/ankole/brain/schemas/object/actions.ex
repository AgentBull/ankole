defmodule Ankole.Brain.Schemas.Object.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.Brain.Schemas.Object`.
  """
  use Ash.Resource.Actions.Implementation

  alias Ankole.Brain.Schemas.Object

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:create_object, %{arguments: args}, _context),
    do: Ankole.Errors.wrap(Ankole.Brain.Objects.create_object_in_tx(args.attrs, args.writer))

  defp action(:update_object, %{arguments: args}, _context) do
    args.slug
    |> Ankole.Brain.Objects.update_object_in_tx(args.attrs, args.writer, author: args[:author])
    |> Ankole.Errors.wrap()
  end

  defp action(:upsert_source_projection, %{arguments: args}, _context) do
    args.source
    |> Ankole.Brain.Objects.upsert_source_projection_in_tx(args.attrs)
    |> Ankole.Errors.wrap()
  end

  defp action(:upsert_library_projection, %{arguments: args}, _context) do
    args.source
    |> Ankole.Brain.Objects.upsert_library_projection_in_tx(args.page)
    |> Ankole.Errors.wrap()
  end

  defp action(:soft_delete_object, %{arguments: args}, _context) do
    args.slug
    |> Ankole.Brain.Objects.soft_delete_in_tx(reason: args[:reason], by: args[:by])
    |> Ankole.Errors.wrap()
  end

  defp action(:rollback_object, %{arguments: args}, _context) do
    args.slug
    |> Ankole.Brain.Objects.rollback_in_tx(args.version_id, args.writer, author: args[:author])
    |> Ankole.Errors.wrap()
  end

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

  defp action(:reconcile_chunks, %{arguments: args}, _context) do
    args.object
    |> Ankole.Brain.Chunks.reconcile_in_tx(chunking: args[:chunking])
    |> Ankole.Errors.wrap()
  end

  defp action(:reconcile_object_links, %{arguments: args}, _context),
    do: Ankole.Errors.wrap(Ankole.Brain.Links.reconcile_object_links_in_tx(args.slug))

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

  defp action(:write_patterns, %{arguments: args}, _context) do
    args.patterns
    |> Ankole.Brain.Patterns.write_patterns_in_tx(args.existing)
    |> Ankole.Errors.wrap()
  end
end
