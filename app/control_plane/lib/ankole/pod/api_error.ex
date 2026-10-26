defmodule Ankole.Pod.APIError do
  @moduledoc "Carries a Pod operation's rejection and conflict details through Ash JSON:API."
  use Splode.Error, fields: [:reason], class: :invalid

  @chat_errors %{
    interaction_not_pending: {409, "This question has an answer or was superseded"},
    invalid_choice: {422, "Select a valid answer"},
    participant_unavailable: {422, "This participant is unavailable"},
    cannot_remove_last_participant: {422, "The room needs an Agent"},
    anchor_page_required: {422, "Select an anchor page to share this discussion"},
    forbidden_room_operation: {403, "Only the room owner or space administrator can do this"},
    conversation_not_found: {404, "Conversation not found"},
    execution_not_found: {404, "Execution not found in this conversation"},
    invalid_execution_cursor: {422, "The execution log cursor is invalid. Reload the log"},
    agent_unavailable: {409, "Agent is unavailable"},
    page_unavailable: {403, "The page is unavailable or you no longer have access to it"},
    conversation_conflict: {409, "Conversation facts conflict"},
    conversation_busy:
      {409, "Wait for the current work to finish before deleting this conversation."},
    invalid_id: {422, "ID is invalid"},
    invalid_text: {422, "Message text is invalid"},
    invalid_attachment: {422, "The attachment upload is invalid"},
    attachment_expired: {422, "The attachment upload expired. Upload it again"},
    reply_unavailable: {409, "Only the latest completed turn can be changed"},
    requires_queue_for_profile:
      {409, "Queue this message to use a different model after the current reply"},
    model_profile_unavailable: {422, "The selected model profile is unavailable"},
    input_already_started: {409, "This input has already started or is no longer pending"},
    queue_changed: {409, "The pending queue changed. Reload it before reordering"}
  }

  def message(error), do: public_error(error.reason).message

  def public_error({:blob_missing, _}), do: public_error(:attachment_expired)

  def public_error(reason) do
    case @chat_errors[reason] do
      {status, message} ->
        %{code: Atom.to_string(reason), message: message, status: status, details: nil}

      nil ->
        value = Ankole.Pod.Serialization.error(reason)
        Map.put(value, :status, Ankole.Pod.Serialization.status(value.code))
    end
  end

  def result(result, project \\ &Function.identity/1)
  def result({:ok, value}, project), do: {:ok, project.(value)}
  def result({:error, error}, _project) when is_exception(error), do: {:error, error}
  def result({:error, reason}, _project), do: {:error, exception(reason: reason)}

  defimpl AshJsonApi.ToJsonApiError do
    def to_json_api_error(error) do
      value = Ankole.Pod.APIError.public_error(error.reason)

      %AshJsonApi.Error{
        status_code: value.status,
        code: value.code,
        title: value.code,
        detail: value.message,
        meta: %{details: value.details}
      }
    end
  end
end
