defmodule Ankole.Ash.OperationResource do
  @moduledoc "Declares typed, stateless operations at an API boundary."
  defmacro __using__(opts) do
    opts = Ankole.Ash.Resource.runtime_authorizers(opts, __CALLER__)

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

      def __tenancy__, do: :tenant

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
