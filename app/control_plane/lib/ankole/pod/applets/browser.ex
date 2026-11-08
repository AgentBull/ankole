defmodule Ankole.Pod.Applets.Browser do
  @moduledoc "Page-authorized Applet environment variable and function inspection operations."
  use Ankole.Ash.OperationResource,
    authorizers: [Ankole.AuthZ.Authorizer],
    data_layer: Ash.DataLayer.Simple,
    domain: Ankole.Pod,
    extensions: [Ankole.AuthZ.Extension, AshJsonApi.Resource]

  alias Ankole.Pod.Applets
  alias Ankole.Pod.Applets.Env
  alias Ankole.Pod.APIError
  alias Ankole.Ash.Types.UUIDv7

  authz do
    scope(:pod)
    allow(:functions, check: :guardrail)
    allow(:status, check: :guardrail)
    allow(:list, check: :guardrail)
    allow(:put, check: :guardrail)
    allow(:delete, check: :guardrail)
    allow(:decrypt, check: :guardrail)
  end

  json_api do
    type("applet_env_operation")
    derive_filter?(false)
    derive_sort?(false)
  end

  @env_item [
    name: [type: :string, allow_nil?: false],
    secret: [type: :boolean, allow_nil?: false],
    required: [type: :boolean, allow_nil?: false],
    declared: [type: :boolean, allow_nil?: false],
    description: [type: :string],
    present: [type: :boolean, allow_nil?: false],
    source: [
      type: :atom,
      allow_nil?: false,
      constraints: [one_of: ~w(applet default pod site missing)a]
    ],
    inherited_source: [
      type: :atom,
      constraints: [one_of: ~w(default pod site)a]
    ],
    value: [type: :string, constraints: [trim?: false, allow_empty?: true]]
  ]

  @route_item [
    method: [
      type: :atom,
      allow_nil?: false,
      constraints: [one_of: ~w(GET POST PUT PATCH DELETE)a]
    ],
    path: [type: :string, allow_nil?: false]
  ]

  @action_item [
    key: [type: :string, allow_nil?: false],
    concurrency: [
      type: :atom,
      allow_nil?: false,
      constraints: [one_of: ~w(parallel serial_fifo serial_coalesce)a]
    ],
    idempotent: [type: :boolean, allow_nil?: false],
    max_slices: [type: :integer, allow_nil?: false]
  ]

  actions do
    action :functions, :map do
      transaction?(false)
      argument(:page_id, UUIDv7, allow_nil?: false)

      constraints(
        fields: [
          has_backend: [type: :boolean, allow_nil?: false],
          revision: [type: :integer, allow_nil?: false],
          routes: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [items: [fields: @route_item]]
          ],
          actions: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [items: [fields: @action_item]]
          ]
        ]
      )

      run(fn input, context ->
        APIError.result(Applets.inspect_functions(context.actor, input.arguments.page_id))
      end)
    end

    action :status, :map do
      transaction?(false)
      argument(:page_id, UUIDv7, allow_nil?: false)

      constraints(
        fields: [
          missing_required_count: [type: :integer, allow_nil?: false]
        ]
      )

      run(fn input, context ->
        APIError.result(Env.status(context.actor, input.arguments.page_id))
      end)
    end

    action :list, :map do
      transaction?(false)
      argument(:page_id, UUIDv7, allow_nil?: false)

      constraints(
        fields: [
          can_decrypt: [type: :boolean, allow_nil?: false],
          envs: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [items: [fields: @env_item]]
          ]
        ]
      )

      run(fn input, context ->
        APIError.result(Env.list(context.actor, input.arguments.page_id))
      end)
    end

    action :put, :map do
      transaction?(false)
      argument(:page_id, UUIDv7, allow_nil?: false)
      argument(:name, :string, allow_nil?: false, constraints: [trim?: false])
      argument(:value, :string, sensitive?: true, constraints: [trim?: false, allow_empty?: true])
      argument(:secret, :boolean)
      argument(:description, :string, constraints: [trim?: false, allow_empty?: true])

      constraints(
        fields: [
          env: [type: :map, allow_nil?: false, constraints: [fields: @env_item]]
        ]
      )

      run(fn input, context ->
        attrs =
          input.arguments
          |> Map.take([:value, :secret, :description])
          |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)

        APIError.result(
          Env.put(context.actor, input.arguments.page_id, input.arguments.name, attrs),
          &%{env: &1}
        )
      end)
    end

    action :delete, :map do
      transaction?(false)
      argument(:page_id, UUIDv7, allow_nil?: false)
      argument(:name, :string, allow_nil?: false, constraints: [trim?: false])

      constraints(
        fields: [
          env: [type: :map, allow_nil?: false, constraints: [fields: @env_item]]
        ]
      )

      run(fn input, context ->
        APIError.result(
          Env.delete(context.actor, input.arguments.page_id, input.arguments.name),
          &%{env: &1}
        )
      end)
    end

    action :decrypt, :map do
      transaction?(false)
      argument(:page_id, UUIDv7, allow_nil?: false)
      argument(:name, :string, allow_nil?: false, constraints: [trim?: false])

      constraints(
        fields: [
          decrypted_value: [
            type: :map,
            allow_nil?: false,
            constraints: [
              fields: [
                name: [type: :string, allow_nil?: false],
                value: [
                  type: :string,
                  allow_nil?: false,
                  constraints: [trim?: false, allow_empty?: true]
                ]
              ]
            ]
          ]
        ]
      )

      run(fn input, context ->
        name = input.arguments.name

        APIError.result(
          Env.decrypt(context.actor, input.arguments.page_id, name),
          &%{decrypted_value: %{name: name, value: &1}}
        )
      end)
    end
  end
end
