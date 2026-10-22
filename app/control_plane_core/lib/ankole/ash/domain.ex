defmodule Ankole.Ash.Domain do
  @moduledoc """
  Declares an Ankole domain: the code interface of one bounded context.

  Each `define` gets the tenant of the calling process through
  `Ankole.Ash.default_options/0`. Principal/AuthZ owns authorization, so Ash
  authorizes only when a caller requests it. The domain list in the
  application configuration is not used.
  """

  defmacro __using__(opts) do
    opts =
      opts
      |> Keyword.put(:validate_config_inclusion?, false)
      |> Keyword.put(:backwards_compatible_interface?, false)
      |> Keyword.update(
        :extensions,
        [Ankole.Ash.DomainExtension],
        &[Ankole.Ash.DomainExtension | &1]
      )

    quote do
      use Ash.Domain, unquote(opts)

      authorization do
        authorize(:when_requested)
      end
    end
  end
end

defmodule Ankole.Ash.DomainExtension do
  @moduledoc false
  use Spark.Dsl.Extension, transformers: [Ankole.Ash.Transformers.DomainDefaults]
end
