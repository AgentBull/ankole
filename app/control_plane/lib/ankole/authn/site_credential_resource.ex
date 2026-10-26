defmodule Ankole.Authn.SiteCredentialResource do
  @moduledoc "The schema contract of a directly addressable, tenant-owned site credential."
  use Spark.Dsl.Extension, verifiers: [Ankole.Authn.SiteCredentialResource.Verifier]
end
