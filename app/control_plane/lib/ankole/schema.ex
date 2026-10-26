defmodule Ankole.Schema do
  @moduledoc """
  Declares an Ecto schema for a table that a registered exception module owns.

  Ash resources own the other tables. `__tenancy__/0` tells `Ankole.Repo`
  whether the rows belong to a tenant or to the site. A tenant schema gets a
  required `tenant_id` from the calling process.
  """

  defmacro __using__(opts) do
    tenancy = Keyword.fetch!(opts, :tenancy)
    tenant_in_primary_key = Keyword.get(opts, :tenant_in_primary_key, false)

    unless tenancy in [:tenant, :site],
      do: raise(ArgumentError, "schema tenancy must be :tenant or :site")

    if tenant_in_primary_key and tenancy != :tenant,
      do: raise(ArgumentError, "a site schema cannot have a tenant primary key")

    quote do
      use Ecto.Schema
      import Ecto.Schema, except: [schema: 2]
      import Ankole.Schema, only: [schema: 2]

      @ankole_tenancy unquote(tenancy)
      @ankole_tenant_in_primary_key unquote(tenant_in_primary_key)

      def __tenancy__, do: unquote(tenancy)
    end
  end

  defmacro schema(source, do: block) do
    quote do
      Ecto.Schema.schema unquote(source) do
        if @ankole_tenancy == :tenant do
          field :tenant_id, Ankole.Ecto.UUIDv7,
            autogenerate: {Ankole.Repo, :tenant_id!, []},
            primary_key: @ankole_tenant_in_primary_key
        end

        unquote(block)
      end
    end
  end
end
