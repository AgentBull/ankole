defmodule AnkoleWeb.JSONAPI.Router do
  @moduledoc """
  Declares a JSON:API router for one browser API scope.

  A router serves the routes that its domains declare in their `json_api`
  sections, and its OpenAPI document at `/openapi.json`. A domain is in one
  router only, and the router gives the path prefix. `AnkoleWeb.Router`
  mounts the router behind the browser session and data-context pipelines of its scope.

  Options:

    * `:scope` - the API scope and OpenAPI title. Console and site scopes
      use `AnkoleWeb.JSONAPI.Policy`; other scopes supply `:before_dispatch`.
    * `:before_dispatch` - the scope's request context callback.
    * `:domains` - the Ash domains of the router.
    * `:prefix` - the mount path, for example `"/api/v2"`.
    * `:rules` - only for a test router: rules that replace the rules of the
      scope.
  """

  defmacro __using__(opts) do
    {scope, opts} = Keyword.pop!(opts, :scope)
    {rules, opts} = Keyword.pop(opts, :rules)
    policy_args = if rules, do: [scope, rules], else: [scope]
    {before_dispatch, opts} = Keyword.pop(opts, :before_dispatch)

    # `AshJsonApi.Router` expands its options in the module body, so each
    # module in them becomes a compile-time dependency of the router. The
    # router calls these modules only when it serves a request: expand them
    # here as runtime references. This module names them only in quoted code,
    # so it has no runtime dependency on the application.
    runtime = %{__CALLER__ | function: {:call, 2}}
    expand = &Macro.expand_literals(&1, runtime)
    open_api = expand.(quote(do: AnkoleWeb.JSONAPI.OpenAPI))
    policy = expand.(quote(do: AnkoleWeb.JSONAPI.Policy))

    before_dispatch =
      if before_dispatch,
        do: expand.(before_dispatch),
        else: quote(do: {unquote(policy), :before_dispatch, unquote(policy_args)})

    opts =
      opts
      |> Keyword.update!(:domains, expand)
      |> Keyword.merge(
        open_api: "/openapi.json",
        phoenix_endpoint: expand.(quote(do: AnkoleWeb.Endpoint)),
        modify_open_api: quote(do: {unquote(open_api), :modify, [unquote(scope)]}),
        before_dispatch: before_dispatch
      )

    quote do
      use AshJsonApi.Router, unquote(opts)

      def call(conn, opts) do
        dispatch = fn -> AnkoleWeb.JSONAPI.Policy.dispatch(conn, &super(&1, opts)) end

        case unquote(scope) do
          :site -> Ankole.Repo.without_tenant(dispatch)
          :console -> dispatch.()
          _ -> super(conn, opts)
        end
      end
    end
  end
end
