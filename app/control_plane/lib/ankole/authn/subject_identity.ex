defmodule Ankole.Authn.SubjectIdentity do
  @moduledoc "The tenant provider namespace and immutable enterprise subject binding contract."
  use Spark.Dsl.Extension, verifiers: [Ankole.Authn.SubjectIdentity.Verifier]
end
