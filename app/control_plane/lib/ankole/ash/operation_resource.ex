defmodule Ankole.Ash.OperationResource do
  @moduledoc """
  Declares typed, stateless operations at an API boundary.

  An operation is tenant-scoped by default. An operation that serves the site
  administration API declares `tenancy: :site`: it runs without a tenant, and
  the site console scope authorizes it. Existing operation callers keep the
  default `tenancy: :tenant`.
  """
  defmacro __using__(opts) do
    opts = Ankole.Ash.Resource.runtime_authorizers(opts, __CALLER__)
    {tenancy, opts} = Keyword.pop(opts, :tenancy, :tenant)

    unless tenancy in [:tenant, :site],
      do: raise(ArgumentError, "operation tenancy must be :tenant or :site")

    quote do
      use Ash.Resource,
          unquote(
            opts
            |> Keyword.put(:data_layer, Ash.DataLayer.Simple)
            |> Keyword.update(
              :extensions,
              [Ankole.Ash.Extension, AshJsonApi.Resource],
              &[Ankole.Ash.Extension, AshJsonApi.Resource | &1]
            )
          )

      def __tenancy__, do: unquote(tenancy)

      import Ankole.Ash.Resource, only: [struct_constraints: 1]

      preparations do
        prepare(Ankole.Ash.TopLevel, on: [:action])
      end

      resource do
        require_primary_key?(false)
      end
    end
  end
end
