defmodule Ankole.AuthZ.Extension do
  @moduledoc "Compile-time authorization declarations, independent of the runtime permission engine."
  use Spark.Dsl.Extension,
    sections: Ankole.AuthZ.Dsl.sections(),
    verifiers: [Ankole.AuthZ.Verifiers.VerifyActionAuthz]
end
