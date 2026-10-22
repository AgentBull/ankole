defmodule Ankole.IdentityProviders.Domain do
  @moduledoc false
  use Ankole.Ash.Domain

  resources do
    resource Ankole.IdentityProviders.DirectoryEvent do
      define(:get_directory_event, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_directory_events, action: :read)
      define(:receive_directory_event, action: :receive_in_tx)
      define(:fail_directory_event, action: :fail_in_tx)
      define(:review_directory_event, action: :review_in_tx)
    end

    resource Ankole.IdentityProviders.DirectoryState do
      define(:get_directory_state, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_directory_states, action: :read)
      define(:ensure_directory_state, action: :ensure_in_tx)
      define(:receive_event_directory_state, action: :receive_event_in_tx)
    end
  end
end
