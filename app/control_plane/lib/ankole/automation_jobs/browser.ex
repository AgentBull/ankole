defmodule Ankole.AutomationJobs.Browser do
  @moduledoc "Page-authorized Applet Jobs and Run progress."
  use Ankole.Ash.OperationResource,
    data_layer: Ash.DataLayer.Simple,
    domain: Ankole.AutomationJobs,
    authorizers: [Ankole.AuthZ.Authorizer],
    extensions: [Ankole.AuthZ.Extension, AshJsonApi.Resource]

  alias Ankole.AutomationJobs.Applet
  alias Ankole.Pod.APIError
  alias Ankole.Ash.Types.{UUIDv7, JSONMap}

  @job [
    type: :struct,
    constraints: struct_constraints(Ankole.AutomationJobs.Schemas.Job),
    allow_nil?: false
  ]
  @run [
    type: :struct,
    constraints: struct_constraints(Ankole.AutomationJobs.Schemas.Run),
    allow_nil?: false
  ]
  resource do
    require_primary_key?(false)
  end

  authz do
    scope(:pod)
    allow(:list, check: :guardrail)
    allow(:create, check: :guardrail)
    allow(:configure, check: :guardrail)
    allow(:delete, check: :guardrail)
    allow(:run, check: :guardrail)
    allow(:actions, check: :guardrail)
    allow(:runs, check: :guardrail)
    allow(:webhooks_delete, check: :guardrail)
    allow(:webhooks_cancel, check: :guardrail)
    allow(:webhooks_resume, check: :guardrail)
    allow(:webhooks_pause, check: :guardrail)
    allow(:webhooks_update, check: :guardrail)
    allow(:webhooks_create, check: :guardrail)
    allow(:webhooks_list, check: :guardrail)
    allow(:schedules_runs, check: :guardrail)
    allow(:schedules_delete, check: :guardrail)
    allow(:schedules_run, check: :guardrail)
    allow(:schedules_resume, check: :guardrail)
    allow(:schedules_pause, check: :guardrail)
    allow(:schedules_put, check: :guardrail)
    allow(:schedules_list, check: :guardrail)
  end

  json_api do
    type("applet_job_operation")
  end

  actions do
    action :actions, :map do
      argument(:page_id, UUIDv7, allow_nil?: false)
      constraints(fields: [actions: [type: {:array, :string}, allow_nil?: false]])

      run(fn input, context ->
        APIError.result(Applet.actions(context.actor, input.arguments.page_id), &%{actions: &1})
      end)
    end

    action :runs, :map do
      argument(:page_id, UUIDv7, allow_nil?: false)
      argument(:job_id, :integer, allow_nil?: false)

      constraints(
        fields: [
          runs: [
            type: {:array, :struct},
            constraints: [items: struct_constraints(Ankole.AutomationJobs.Schemas.Run)],
            allow_nil?: false
          ]
        ]
      )

      run(fn input, context ->
        APIError.result(
          Applet.runs(context.actor, input.arguments.page_id, input.arguments.job_id),
          &%{runs: &1}
        )
      end)
    end

    action :schedules_list, JSONMap do
      argument(:page_id, UUIDv7, allow_nil?: false)
      argument(:job_id, :integer, allow_nil?: false)

      run(fn input, context ->
        APIError.result(
          Ankole.AutomationJobs.JobSources.schedules(
            context.actor,
            input.arguments.page_id,
            input.arguments.job_id,
            :list,
            Map.reject(input.arguments, fn {_, value} -> is_nil(value) end)
          ),
          &%{result: Ankole.Pod.Serialization.json_value(&1)}
        )
      end)
    end

    action :schedules_put, JSONMap do
      argument(:page_id, UUIDv7, allow_nil?: false)
      argument(:job_id, :integer, allow_nil?: false)
      argument(:id, UUIDv7)
      argument(:name, :string)
      argument(:schedule, JSONMap)
      argument(:timezone, :string)
      argument(:payload, JSONMap)
      argument(:idempotency_key, :string)

      run(fn input, context ->
        APIError.result(
          Ankole.AutomationJobs.JobSources.schedules(
            context.actor,
            input.arguments.page_id,
            input.arguments.job_id,
            :put,
            Map.reject(input.arguments, fn {_, value} -> is_nil(value) end)
          ),
          &%{result: Ankole.Pod.Serialization.json_value(&1)}
        )
      end)
    end

    action :schedules_pause, JSONMap do
      argument(:page_id, UUIDv7, allow_nil?: false)
      argument(:job_id, :integer, allow_nil?: false)
      argument(:id, UUIDv7, allow_nil?: false)

      run(fn input, context ->
        APIError.result(
          Ankole.AutomationJobs.JobSources.schedules(
            context.actor,
            input.arguments.page_id,
            input.arguments.job_id,
            :pause,
            Map.reject(input.arguments, fn {_, value} -> is_nil(value) end)
          ),
          &%{result: Ankole.Pod.Serialization.json_value(&1)}
        )
      end)
    end

    action :schedules_resume, JSONMap do
      argument(:page_id, UUIDv7, allow_nil?: false)
      argument(:job_id, :integer, allow_nil?: false)
      argument(:id, UUIDv7, allow_nil?: false)

      run(fn input, context ->
        APIError.result(
          Ankole.AutomationJobs.JobSources.schedules(
            context.actor,
            input.arguments.page_id,
            input.arguments.job_id,
            :resume,
            Map.reject(input.arguments, fn {_, value} -> is_nil(value) end)
          ),
          &%{result: Ankole.Pod.Serialization.json_value(&1)}
        )
      end)
    end

    action :schedules_run, JSONMap do
      argument(:page_id, UUIDv7, allow_nil?: false)
      argument(:job_id, :integer, allow_nil?: false)
      argument(:id, UUIDv7, allow_nil?: false)
      argument(:idempotency_key, :string, allow_nil?: false)

      run(fn input, context ->
        APIError.result(
          Ankole.AutomationJobs.JobSources.schedules(
            context.actor,
            input.arguments.page_id,
            input.arguments.job_id,
            :run,
            Map.reject(input.arguments, fn {_, value} -> is_nil(value) end)
          ),
          &%{result: Ankole.Pod.Serialization.json_value(&1)}
        )
      end)
    end

    action :schedules_delete, JSONMap do
      argument(:page_id, UUIDv7, allow_nil?: false)
      argument(:job_id, :integer, allow_nil?: false)
      argument(:id, UUIDv7, allow_nil?: false)

      run(fn input, context ->
        APIError.result(
          Ankole.AutomationJobs.JobSources.schedules(
            context.actor,
            input.arguments.page_id,
            input.arguments.job_id,
            :delete,
            Map.reject(input.arguments, fn {_, value} -> is_nil(value) end)
          ),
          &%{result: Ankole.Pod.Serialization.json_value(&1)}
        )
      end)
    end

    action :schedules_runs, JSONMap do
      argument(:page_id, UUIDv7, allow_nil?: false)
      argument(:job_id, :integer, allow_nil?: false)
      argument(:id, UUIDv7, allow_nil?: false)

      run(fn input, context ->
        APIError.result(
          Ankole.AutomationJobs.JobSources.schedules(
            context.actor,
            input.arguments.page_id,
            input.arguments.job_id,
            :runs,
            Map.reject(input.arguments, fn {_, value} -> is_nil(value) end)
          ),
          &%{result: Ankole.Pod.Serialization.json_value(&1)}
        )
      end)
    end

    action :webhooks_list, JSONMap do
      argument(:page_id, UUIDv7, allow_nil?: false)
      argument(:job_id, :integer, allow_nil?: false)

      run(fn input, context ->
        APIError.result(
          Ankole.AutomationJobs.JobSources.webhooks(
            context.actor,
            input.arguments.page_id,
            input.arguments.job_id,
            :list,
            Map.reject(input.arguments, fn {_, value} -> is_nil(value) end)
          ),
          &%{result: Ankole.Pod.Serialization.json_value(&1)}
        )
      end)
    end

    action :webhooks_create, JSONMap do
      argument(:page_id, UUIDv7, allow_nil?: false)
      argument(:job_id, :integer, allow_nil?: false)
      argument(:label, :string, allow_nil?: false)
      argument(:expires_at, :utc_datetime_usec, allow_nil?: false)

      argument(:mode, :string,
        default: "standing",
        constraints: [match: ~r/\A(standing|one_shot)\z/]
      )

      argument(:event_format, :string,
        default: "raw",
        constraints: [match: ~r/\A(raw|cloudevents)\z/]
      )

      run(fn input, context ->
        APIError.result(
          Ankole.AutomationJobs.JobSources.webhooks(
            context.actor,
            input.arguments.page_id,
            input.arguments.job_id,
            :create,
            Map.reject(input.arguments, fn {_, value} -> is_nil(value) end)
          ),
          &%{result: Ankole.Pod.Serialization.json_value(&1)}
        )
      end)
    end

    action :webhooks_update, JSONMap do
      argument(:page_id, UUIDv7, allow_nil?: false)
      argument(:job_id, :integer, allow_nil?: false)
      argument(:id, UUIDv7, allow_nil?: false)
      argument(:label, :string)
      argument(:expires_at, :utc_datetime_usec)

      run(fn input, context ->
        APIError.result(
          Ankole.AutomationJobs.JobSources.webhooks(
            context.actor,
            input.arguments.page_id,
            input.arguments.job_id,
            :update,
            Map.reject(input.arguments, fn {_, value} -> is_nil(value) end)
          ),
          &%{result: Ankole.Pod.Serialization.json_value(&1)}
        )
      end)
    end

    action :webhooks_pause, JSONMap do
      argument(:page_id, UUIDv7, allow_nil?: false)
      argument(:job_id, :integer, allow_nil?: false)
      argument(:id, UUIDv7, allow_nil?: false)

      run(fn input, context ->
        APIError.result(
          Ankole.AutomationJobs.JobSources.webhooks(
            context.actor,
            input.arguments.page_id,
            input.arguments.job_id,
            :pause,
            Map.reject(input.arguments, fn {_, value} -> is_nil(value) end)
          ),
          &%{result: Ankole.Pod.Serialization.json_value(&1)}
        )
      end)
    end

    action :webhooks_resume, JSONMap do
      argument(:page_id, UUIDv7, allow_nil?: false)
      argument(:job_id, :integer, allow_nil?: false)
      argument(:id, UUIDv7, allow_nil?: false)

      run(fn input, context ->
        APIError.result(
          Ankole.AutomationJobs.JobSources.webhooks(
            context.actor,
            input.arguments.page_id,
            input.arguments.job_id,
            :resume,
            Map.reject(input.arguments, fn {_, value} -> is_nil(value) end)
          ),
          &%{result: Ankole.Pod.Serialization.json_value(&1)}
        )
      end)
    end

    action :webhooks_cancel, JSONMap do
      argument(:page_id, UUIDv7, allow_nil?: false)
      argument(:job_id, :integer, allow_nil?: false)
      argument(:id, UUIDv7, allow_nil?: false)

      run(fn input, context ->
        APIError.result(
          Ankole.AutomationJobs.JobSources.webhooks(
            context.actor,
            input.arguments.page_id,
            input.arguments.job_id,
            :cancel,
            Map.reject(input.arguments, fn {_, value} -> is_nil(value) end)
          ),
          &%{result: Ankole.Pod.Serialization.json_value(&1)}
        )
      end)
    end

    action :webhooks_delete, JSONMap do
      argument(:page_id, UUIDv7, allow_nil?: false)
      argument(:job_id, :integer, allow_nil?: false)
      argument(:id, UUIDv7, allow_nil?: false)

      run(fn input, context ->
        APIError.result(
          Ankole.AutomationJobs.JobSources.webhooks(
            context.actor,
            input.arguments.page_id,
            input.arguments.job_id,
            :delete,
            Map.reject(input.arguments, fn {_, value} -> is_nil(value) end)
          ),
          &%{result: Ankole.Pod.Serialization.json_value(&1)}
        )
      end)
    end

    action :list, :map do
      argument(:page_id, UUIDv7, allow_nil?: false)

      constraints(
        fields: [
          jobs: [
            type: {:array, :struct},
            constraints: [items: struct_constraints(Ankole.AutomationJobs.Schemas.Job)],
            allow_nil?: false
          ]
        ]
      )

      run(fn input, context ->
        APIError.result(Applet.list(context.actor, input.arguments.page_id), &%{jobs: &1})
      end)
    end

    action :create, :map do
      constraints(fields: [job: @job])
      argument(:page_id, UUIDv7, allow_nil?: false)
      argument(:action_key, :string, allow_nil?: false)

      argument(:authorization_kind, :string,
        default: "human",
        constraints: [match: ~r/\A(human|service)\z/]
      )

      argument(:config, JSONMap, default: %{})
      argument(:label, :string)

      run(fn input, context ->
        APIError.result(
          Applet.create(
            context.actor,
            input.arguments.page_id,
            input.arguments.action_key,
            Map.reject(input.arguments, fn {_, v} -> is_nil(v) end)
          ),
          &%{job: &1}
        )
      end)
    end

    action :configure, :map do
      constraints(fields: [job: @job])
      argument(:page_id, UUIDv7, allow_nil?: false)
      argument(:id, :integer, allow_nil?: false)
      argument(:config, JSONMap)
      argument(:label, :string)

      run(fn input, context ->
        APIError.result(
          Applet.configure(
            context.actor,
            input.arguments.page_id,
            input.arguments.id,
            Map.reject(input.arguments, fn {_, v} -> is_nil(v) end)
          ),
          &%{job: &1}
        )
      end)
    end

    action :delete, :map do
      constraints(fields: [job: @job])
      argument(:page_id, UUIDv7, allow_nil?: false)
      argument(:id, :integer, allow_nil?: false)

      run(fn input, context ->
        APIError.result(
          Applet.delete(context.actor, input.arguments.page_id, input.arguments.id),
          &%{job: &1}
        )
      end)
    end

    action :run, :map do
      constraints(fields: [run: @run])
      argument(:page_id, UUIDv7, allow_nil?: false)
      argument(:id, :integer, allow_nil?: false)

      run(fn input, context ->
        APIError.result(
          Applet.run(context.actor, input.arguments.page_id, input.arguments.id),
          &%{run: &1}
        )
      end)
    end
  end
end
