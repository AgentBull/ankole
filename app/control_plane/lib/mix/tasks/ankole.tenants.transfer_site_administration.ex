defmodule Mix.Tasks.Ankole.Tenants.TransferSiteAdministration do
  @moduledoc "Transfers site administration to an active Human in the target tenant."
  use Mix.Task
  @shortdoc "Transfers site administration without bypassing the tenant lifecycle owner"

  @impl Mix.Task
  def run([slug, uid]) do
    Mix.Task.run("app.config")
    :ok = Ankole.Release.transfer_site_administration(slug, uid)
    Mix.shell().info("Site administration transferred to #{slug}.")
  end

  def run(_) do
    Mix.raise("Usage: mix ankole.tenants.transfer_site_administration TENANT_SLUG HUMAN_UID")
  end
end
