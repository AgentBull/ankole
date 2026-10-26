defmodule Ankole.Authn do
  @moduledoc "Declarative site credential and Pod enterprise authentication strategies."
  use Spark.Dsl.Extension,
    sections: Ankole.Authn.Dsl.sections(),
    transformers: [Ankole.Authn.Transformer],
    verifiers: [Ankole.Authn.Verifier]
end
