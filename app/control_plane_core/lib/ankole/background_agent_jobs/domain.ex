defmodule Ankole.BackgroundAgentJobs.Domain do
  @moduledoc false
  use Ankole.Ash.Domain

  resources do
    resource Ankole.BackgroundAgentJobs.Schemas.Job do
      define(:get_job, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_jobs, action: :read)
      define(:record_lessons_applied_job, action: :record_lessons_applied)
      define(:touch_job, action: :touch)
      define(:begin_worker_wait_job, action: :begin_worker_wait)
      define(:clear_worker_wait_job, action: :clear_worker_wait)
      define(:record_applied_signal_job, action: :record_applied_signal)
      define(:reauthorize_job, action: :reauthorize)
      define(:create_job, action: :create_job)
    end

    resource Ankole.BackgroundAgentJobs.Schemas.Turn do
      define(:get_turn, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_turns, action: :read)
      define(:record_turn, action: :record)
      define(:mark_content_truncated_turn, action: :mark_content_truncated)
    end

    resource Ankole.BackgroundAgentJobs.Schemas.TurnItem do
      define(:get_turn_item,
        action: :read,
        get_by: [:turn_id, :position],
        not_found_error?: false
      )

      define(:list_turn_items, action: :read)
      define(:append_turn_item, action: :append)
    end
  end
end
