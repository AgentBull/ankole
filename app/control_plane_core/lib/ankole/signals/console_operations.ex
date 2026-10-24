defmodule Ankole.Signals.ConsoleOperations do
  @moduledoc "Typed Console operations that call the Ankole.Signals owner."
  use Ash.Resource,
    data_layer: Ash.DataLayer.Simple,
    domain: Ankole.Signals,
    extensions: [AshJsonApi.Resource]

  resource do
    require_primary_key?(false)
  end

  json_api do
    type("signals_operation")
    derive_filter?(false)
    derive_sort?(false)
  end

  actions do
    action :console_adapters, :map do
      transaction?(false)

      constraints(
        fields: [
          signal_adapters: [
            type: {:array, :map},
            constraints: [
              items: [
                fields: [
                  adapter_category: [
                    type: :atom,
                    constraints: [one_of: [:enterprise_im, :consumer_im, :email, :event_source]],
                    allow_nil?: false
                  ],
                  adapter_id: [
                    type: :string,
                    constraints: [trim?: false, allow_empty?: true],
                    allow_nil?: false
                  ],
                  display_name: [type: Ankole.Ash.Types.JSONValue],
                  fields: [type: {:array, Ankole.Ash.Types.JSONMap}, allow_nil?: false],
                  group_message_mode_field: [type: Ankole.Ash.Types.JSONMap],
                  plugin_id: [type: :string, constraints: [trim?: false, allow_empty?: true]],
                  unmatched_sender_policy_field: [type: Ankole.Ash.Types.JSONMap]
                ]
              ]
            ],
            allow_nil?: false
          ]
        ]
      )

      run(Ankole.Signals.ConsoleActions)
    end

    action :console_list_bindings, :map do
      transaction?(false)

      constraints(
        fields: [
          delivery_failures: [
            type: {:array, :map},
            constraints: [
              items: [
                fields: [
                  agent_uid: [
                    type: :string,
                    constraints: [trim?: false, allow_empty?: true],
                    allow_nil?: false
                  ],
                  attempt_count: [type: :integer, allow_nil?: false],
                  binding_name: [
                    type: :string,
                    constraints: [trim?: false, allow_empty?: true],
                    allow_nil?: false
                  ],
                  can_retry: [type: :boolean, allow_nil?: false],
                  max_attempts: [type: :integer, allow_nil?: false],
                  outbound_key: [
                    type: :string,
                    constraints: [trim?: false, allow_empty?: true],
                    allow_nil?: false
                  ],
                  possible_duplicate: [type: :boolean, allow_nil?: false],
                  state: [
                    type: :atom,
                    constraints: [one_of: [:blocked, :permanent, :exhausted]],
                    allow_nil?: false
                  ],
                  status: [
                    type: :atom,
                    constraints: [one_of: [:failed, :expired, :unknown]],
                    allow_nil?: false
                  ],
                  updated_at: [
                    type: :string,
                    constraints: [trim?: false, allow_empty?: true],
                    allow_nil?: false
                  ]
                ]
              ]
            ],
            allow_nil?: false
          ],
          signal_bindings: [
            type: {:array, Ankole.Signals.ConsoleBinding},
            allow_nil?: false
          ]
        ]
      )

      argument(:agent, :string, constraints: [trim?: false, allow_empty?: true])
      run(Ankole.Signals.ConsoleActions)
    end

    action :console_get_binding, :map do
      transaction?(false)

      constraints(
        fields: [
          config: [type: Ankole.Ash.Types.JSONValue, allow_nil?: false],
          signal_binding: [type: Ankole.Signals.ConsoleBinding, allow_nil?: false],
          stored_secret_paths: [
            type: {:array, :string},
            constraints: [items: [trim?: false, allow_empty?: true]],
            allow_nil?: false
          ]
        ]
      )

      argument(:agent_uid, :string,
        allow_nil?: false,
        constraints: [trim?: false, allow_empty?: true]
      )

      argument(:binding_name, :string,
        allow_nil?: false,
        constraints: [trim?: false, allow_empty?: true]
      )

      run(Ankole.Signals.ConsoleActions)
    end

    action :console_put_binding, :map do
      transaction?(false)

      constraints(
        fields: [signal_binding: [type: Ankole.Signals.ConsoleBinding, allow_nil?: false]]
      )

      argument(:agent_uid, :string,
        allow_nil?: false,
        constraints: [trim?: false, allow_empty?: true]
      )

      argument(:adapter_id, :string,
        allow_nil?: false,
        constraints: [trim?: false, allow_empty?: true]
      )

      argument(:binding_name, :string,
        allow_nil?: false,
        constraints: [trim?: false, allow_empty?: true]
      )

      argument(:config, Ankole.Ash.Types.JSONMap, allow_nil?: false, sensitive?: true)
      argument(:target, Ankole.Ash.Types.JSONValue)
      argument(:filters, Ankole.Ash.Types.JSONValue)
      argument(:group_message_mode, :string, constraints: [trim?: false, allow_empty?: true])
      argument(:unmatched_sender_policy, :string, constraints: [trim?: false, allow_empty?: true])
      run(Ankole.Signals.ConsoleActions)
    end

    action :console_update_binding, :map do
      transaction?(false)

      constraints(
        fields: [signal_binding: [type: Ankole.Signals.ConsoleBinding, allow_nil?: false]]
      )

      argument(:agent_uid, :string,
        allow_nil?: false,
        constraints: [trim?: false, allow_empty?: true]
      )

      argument(:target_agent_uid, :string,
        allow_nil?: false,
        constraints: [trim?: false, allow_empty?: true]
      )

      argument(:binding_name, :string,
        allow_nil?: false,
        constraints: [trim?: false, allow_empty?: true]
      )

      argument(:config, Ankole.Ash.Types.JSONMap, allow_nil?: false, sensitive?: true)
      argument(:target, Ankole.Ash.Types.JSONValue)
      argument(:filters, Ankole.Ash.Types.JSONValue)
      argument(:group_message_mode, :string, constraints: [trim?: false, allow_empty?: true])
      argument(:unmatched_sender_policy, :string, constraints: [trim?: false, allow_empty?: true])
      run(Ankole.Signals.ConsoleActions)
    end

    action :console_requeue, :map do
      transaction?(false)
      constraints(fields: [requeued: [type: :boolean, allow_nil?: false]])

      argument(:agent_uid, :string,
        allow_nil?: false,
        constraints: [trim?: false, allow_empty?: true]
      )

      argument(:binding_name, :string,
        allow_nil?: false,
        constraints: [trim?: false, allow_empty?: true]
      )

      argument(:outbound_key, :string,
        allow_nil?: false,
        constraints: [trim?: false, allow_empty?: true]
      )

      run(Ankole.Signals.ConsoleActions)
    end
  end
end
