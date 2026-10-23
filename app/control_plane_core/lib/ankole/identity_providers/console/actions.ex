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

  defp action(:save_provider, args, _context) do
    with {:ok, _} <-
           IdentityProviders.save_provider(
             args.provider_id,
             args.adapter_id,
             args.config,
             args.enabled != false,
             source: "console"
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

  defp actor(context), do: Ankole.ActorRef.from_principal(context.actor)

  defp describe(reason) when reason in [:not_found, :unknown_identity_provider_adapter],
    do: Ankole.Errors.Invalid.NotFound.exception(resource: IdentityProviders)

  defp describe({reason, _})
       when reason in [:unknown_identity_provider, :unknown_identity_provider_adapter],
       do: Ankole.Errors.Invalid.NotFound.exception(resource: IdentityProviders)

  defp describe(:platform_app_bound_to_another_tenant),
    do: {:conflict, "This platform application belongs to another tenant.", []}

  defp describe({:platform_application_identity_unavailable, reference}),
    do:
      {"Could not verify an existing platform application. Repair its credentials and try again.",
       [reference]}

  defp describe(:platform_application_identity_unavailable),
    do: {"Could not verify the platform application. Check its credentials and availability.", []}

  defp describe(:sync_disabled), do: {"Directory sync is disabled for this provider.", []}
  defp describe(:sync_unsupported), do: {"This provider does not support directory sync.", []}

  defp describe({:local_provider_exists, id}),
    do: {"A local password provider already exists. Edit it instead.", [%{provider_id: id}]}

  defp describe(:directory_review_changed),
    do:
      {:conflict,
       "The directory evidence changed. Read the current snapshot and review it again.", []}

  defp describe({:missing, path}),
    do: {"#{path} is required.", [%{path: to_string(path), kind: "missing"}]}

  defp describe({reason, path})
       when reason in [:invalid_string, :invalid_field, :invalid_boolean] and is_binary(path),
       do: {"#{path} is invalid.", [%{path: path, kind: "invalid"}]}

  defp describe({:invalid_integer_range, path, min, max}),
    do:
      {"#{path} must be an integer between #{min} and #{max}.", [%{path: path, kind: "invalid"}]}

  defp describe({:invalid_enum, path, values}),
    do: {"#{path} must be one of: #{Enum.join(values, ", ")}.", [%{path: path, kind: "invalid"}]}

  defp describe({:invalid_id, field, _}),
    do:
      {"The identifier is invalid.",
       [%{path: to_string(field), message: "is not a valid identifier"}]}

  defp describe(_), do: nil
end
