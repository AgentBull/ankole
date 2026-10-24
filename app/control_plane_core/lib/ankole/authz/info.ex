defmodule Ankole.AuthZ.Info do
  @moduledoc false
  use Spark.InfoGenerator, extension: Ankole.AuthZ.Extension, sections: [:authz]
  defdelegate rules(resource), to: Ankole.AuthZ.Dsl
  defdelegate rule(resource, name), to: Ankole.AuthZ.Dsl
  defdelegate params(resource), to: Ankole.AuthZ.Dsl
end
