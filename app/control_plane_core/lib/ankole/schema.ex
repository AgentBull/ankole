defmodule Ankole.Schema do
  @moduledoc """
  Declares whether durable rows belong to a tenant or the site.
  """

  defmacro __using__(opts) do
    tenancy = Keyword.fetch!(opts, :tenancy)
    tenant_in_primary_key = Keyword.get(opts, :tenant_in_primary_key, false)

    unless tenancy in [:tenant, :site] do
      raise ArgumentError, "schema tenancy must be :tenant or :site"
    end

    if tenant_in_primary_key and tenancy != :tenant do
      raise ArgumentError, "a site schema cannot have a tenant primary key"
    end

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
