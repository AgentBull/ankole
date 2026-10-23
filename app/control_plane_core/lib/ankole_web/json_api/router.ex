defmodule AnkoleWeb.JSONAPI.Router do
  @moduledoc """
  Declares a JSON:API router for one scope of the Console API.

  A router serves the routes that its domains declare in their `json_api`
  sections, and its OpenAPI document at `/openapi.json`. A domain is in one
  router only, and the router gives the path prefix. `AnkoleWeb.Router`
  mounts the router behind the same pipelines as the v1 routes of its scope.

  Options:

    * `:scope` - `:site` or `:console`. It selects the rules of
      `AnkoleWeb.JSONAPI.Policy`, the tenant, and the OpenAPI title.
    * `:domains` - the Ash domains of the router.
    * `:prefix` - the mount path, for example `"/api/v2"`.
    * `:rules` - only for a test router: rules that replace the rules of the
      scope.
  """

  defmacro __using__(opts) do
    {scope, opts} = Keyword.pop!(opts, :scope)
    {rules, opts} = Keyword.pop(opts, :rules)
    policy_args = if rules, do: [scope, rules], else: [scope]

    opts =
      Keyword.merge(opts,
        open_api: "/openapi.json",
        phoenix_endpoint: AnkoleWeb.Endpoint,
        modify_open_api: quote(do: {AnkoleWeb.JSONAPI.OpenAPI, :modify, [unquote(scope)]}),
        before_dispatch:
          quote(do: {AnkoleWeb.JSONAPI.Policy, :before_dispatch, unquote(policy_args)})
      )

    quote do
      use AshJsonApi.Router, unquote(opts)

      def call(conn, opts),
        do: AnkoleWeb.JSONAPI.Policy.dispatch(conn, &super(&1, opts))
    end
  end
end
