defmodule Ankole.AutomationJobs.Domain do
  @moduledoc false
  use Ankole.Ash.Domain

  resources do
    resource Ankole.AutomationJobs.Schemas.Job do
      define(:get_job, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_jobs, action: :read)
      define(:create_job, action: :create)
      define(:finish_script_import_job, action: :finish_script_import)
      define(:reauthorize_job, action: :reauthorize)
    end

    resource Ankole.AutomationJobs.Schemas.Run do
      define(:get_run, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_runs, action: :read)
      define(:enqueue_run, action: :enqueue)
      define(:wait_for_worker_run, action: :wait_for_worker)
      define(:record_error_run, action: :record_error)
    end
  end
end
