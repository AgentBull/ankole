defmodule Ankole.TenantContextMissing do
  @moduledoc """
  Raised when tenant data is accessed without an explicit tenant context.
  """

  defexception [:query]

  @impl true
  def message(%{query: query}) do
    source = if query, do: inspect(query.from.source), else: "tenant data"

    "no tenant context for #{source}; set the tenant at the entry point or explicitly use Repo.across_tenants/1"
  end
end
