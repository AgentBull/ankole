defmodule Ankole.Release do
  @moduledoc """
  One-shot control-plane operations for production releases without Mix installed.
  """

  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.IdentityProviders.LocalPassword
  alias Ankole.Principals.LocalPasswordResetText
  alias Ankole.Repo

  @app :ankole

  @doc "Runs all pending database migrations."
  @spec migrate() :: :ok
  def migrate do
    load_app()
    with_repo(&Ankole.Migrations.migrate(&1, Ankole.Migrations.paths(), :up, all: true))

    :ok
  end

  @doc "Resets the local sign-in password for one email and prints the new one-time password."
  @spec reset_local_password(String.t()) :: :ok
  def reset_local_password(email) when is_binary(email) do
    load_app()
    {:ok, _apps} = Application.ensure_all_started(:ankole_kernel)

    with_repo(fn _repo ->
      start_child!(Registry)
      start_pubsub!()
      start_child!(Cache)

      {:ok, tenant} = Ankole.Tenants.privileged()
      Repo.put_tenant_id(tenant.id)

      case LocalPassword.reset_local_password_by_email(email) do
        {:ok, %{initial_password: initial_password}} ->
          IO.puts(LocalPasswordResetText.success(initial_password))

          case LocalPassword.enabled?() do
            true -> :ok
            false -> IO.puts(LocalPasswordResetText.provider_disabled_warning())
          end

        {:error, :not_found} ->
          raise LocalPasswordResetText.no_account_message(email)

        {:error, reason} ->
          raise "failed to reset the local password: #{inspect(reason)}"
      end
    end)

    :ok
  end

  @doc "Records administrator recovery after the operator independently verifies the active Human."
  @spec recover_admin(String.t(), String.t(), String.t()) :: :ok
  def recover_admin(uid, operator, reason) do
    load_app()
    {:ok, _apps} = Application.ensure_all_started(:ankole_kernel)

    with_repo(fn _repo ->
      start_child!(Registry)
      start_pubsub!()
      start_child!(Cache)

      case Ankole.Principals.HumanAccess.recover_admin(uid, operator, reason) do
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

  defp start_child!(module) do
    case module.start_link([]) do
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
