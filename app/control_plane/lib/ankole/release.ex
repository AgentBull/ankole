defmodule Ankole.Release do
  @moduledoc """
  One-shot control-plane operations for production releases without Mix installed.
  """

  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.Repo

  @app :ankole

  @doc "Runs all pending database migrations."
  @spec migrate() :: :ok
  def migrate do
    load_app()
    with_repo(&Ankole.Migrations.migrate(&1, Ankole.Migrations.paths(), :up, all: true))

    :ok
  end

  @doc "Updates the encrypted site SMTP configuration from a JSON object."
  def put_authn_mail(json) when is_binary(json) do
    load_app()
    {:ok, _apps} = Application.ensure_all_started(:ankole_kernel)
    {:ok, settings} = Ankole.JSON.decode(json)

    with_repo(fn _repo ->
      start_child!(Registry)
      start_pubsub!()
      start_child!(Cache)

      case Ankole.Authn.Config.put_mail(settings) do
        {:ok, _} ->
          IO.puts("Site authentication mail configuration saved.")

        {:error, reason} ->
          raise "Cannot save site authentication mail configuration: #{inspect(reason)}"
      end
    end)

    :ok
  end

  @doc "Records administrator recovery after the operator independently verifies the active Human."
  @spec recover_admin(String.t(), String.t(), String.t()) :: :ok
  @spec recover_admin(String.t(), String.t(), String.t(), String.t() | nil) :: :ok
  def recover_admin(uid, operator, reason, tenant_slug \\ nil) do
    load_app()
    {:ok, _apps} = Application.ensure_all_started(:ankole_kernel)

    with_repo(fn _repo ->
      start_child!(Registry)
      start_pubsub!()
      start_child!(Cache)

      result =
        if tenant_slug do
          start_child!(Ankole.Plugins.Registry, name: Ankole.Plugins.Registry)

          with {:ok, tenant} <- Ankole.Tenants.active_by_slug(tenant_slug),
               do:
                 Ankole.Principals.HumanAccess.recover_pod_admin(tenant.id, uid, operator, reason)
        else
          Ankole.Principals.HumanAccess.recover_admin(uid, operator, reason)
        end

      case result do
        {:ok, principal} -> IO.puts("Administrator access restored for #{principal.uid}.")
        {:error, error} -> raise "Administrator recovery failed: #{inspect(error)}"
      end
    end)

    :ok
  end

  @doc "Transfers site administration through the same tenant lifecycle owner as the console."
  def transfer_site_administration(slug, uid) when is_binary(slug) and is_binary(uid) do
    load_app()
    {:ok, _apps} = Application.ensure_all_started(:ankole_kernel)

    with_repo(fn _repo ->
      start_child!(Registry)
      start_pubsub!()
      start_child!(Cache)

      case Ankole.Tenants.list_tenants!(query: [filter: [slug: slug]]) do
        [] ->
          raise "tenant not found: #{slug}"

        [tenant] ->
          case Ankole.Tenants.transfer_site_administration(tenant, uid) do
            {:ok, _} -> :ok
            {:error, reason} -> raise "site administration transfer failed: #{inspect(reason)}"
          end
      end
    end)
  end

  defp start_child!(module, opts \\ []) do
    case module.start_link(opts) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> raise "failed to start #{inspect(module)}: #{inspect(reason)}"
    end
  end

  defp start_pubsub! do
    {:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)

    case Phoenix.PubSub.Supervisor.start_link(name: Ankole.PubSub) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> raise "failed to start PubSub: #{inspect(reason)}"
    end
  end

  defp with_repo(fun) do
    {:ok, result, _apps} = Ecto.Migrator.with_repo(Repo, fun)
    result
  end

  defp load_app do
    {:ok, _apps} = Application.ensure_all_started(:ssl)
    :ok = Application.ensure_loaded(@app)
  end
end
