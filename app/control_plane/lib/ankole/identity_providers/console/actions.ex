defmodule Ankole.IdentityProviders.Console.Actions do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  alias Ankole.IdentityProviders
  alias Ankole.IdentityProviders.DirectoryAccess
  alias Ankole.IdentityProviders.DirectorySync

  @impl true
  def run(input, _opts, context) do
    action(input.action.name, input.arguments, context)
    |> Ankole.Errors.wrap(&describe/1)
  end

  defp action(:adapters, _args, _context) do
    {:ok,
     %{
       identity_provider_adapters:
         Enum.map(
           IdentityProviders.list_adapters(),
           &Map.take(&1, [
             :adapter_id,
             :plugin_id,
             :display_name,
             :capabilities,
             :fields,
             :default_provider_id
           ])
         )
     }}
  end

  defp action(:providers, _args, _context) do
    with {:ok, providers} <- IdentityProviders.list_configured_providers(),
         do: {:ok, %{identity_providers: providers}}
  end

  defp action(operation, args, _context) when operation in [:create_provider, :save_provider] do
    with {:ok, _} <-
           IdentityProviders.save_provider(
             args.provider_id,
             args.adapter_id,
             args.config,
             args.enabled != false,
             source: "console",
             mode: if(operation == :create_provider, do: :create, else: :update)
           ),
         {:ok, provider} <- IdentityProviders.fetch_configured_provider(args.provider_id) do
      {:ok, %{identity_provider: provider}}
    end
  end

  defp action(:run_sync, args, _context) do
    with {:ok, job} <-
           DirectorySync.enqueue_sync(args.provider_id, reason: "manual", source: "console") do
      {:ok, %{sync_run: %{provider_id: args.provider_id, status: "enqueued", job_id: job.id}}}
    end
  end

  defp action(:directory, args, _context),
    do: {:ok, DirectoryAccess.console_view(args.provider_id)}

  defp action(:approve_directory, args, context) do
    with {:ok, _} <-
           DirectoryAccess.approve_snapshot(
             args.provider_id,
             args.snapshot_fingerprint,
             actor(context),
             args.reason,
             args.confirm_removals
           ),
         do: {:ok, DirectoryAccess.console_view(args.provider_id)}
  end

  defp action(:review_event, args, context) do
    case DirectoryAccess.get_event(args.event_id) do
      %{provider_id: provider_id} when provider_id == args.provider_id ->
        case DirectoryAccess.review_event(args.event_id, actor(context), args.reason, args.action) do
          :ok -> {:ok, DirectoryAccess.console_view(args.provider_id)}
          {:ok, _} -> {:ok, DirectoryAccess.console_view(args.provider_id)}
          error -> error
        end

      _ ->
        {:error, :not_found}
    end
  end

  defp actor(context), do: Ankole.ActorRef.from_actor(context.actor)

  defp describe(reason), do: Ankole.IdentityProviders.ErrorDescription.describe(reason)
end
