defmodule Ankole.Pod.APIError do
  @moduledoc "Carries a Pod operation's rejection and conflict details through Ash JSON:API."
  use Splode.Error, fields: [:reason], class: :invalid

  @chat_errors %{
    stale: {409, "This item changed. Reload it before saving."},
    skill_enabled_for_all:
      {409,
       "This Skill is enabled for every Agent. Turn off the global setting before changing individual bindings."},
    official_skill: {422, "Official Skills cannot be renamed or deleted."},
    required_manifest: {422, "Edit SKILL.md through the manifest editor."},
    invalid_skill_manifest: {422, "A Skill requires a name, description and valid content."},
    invalid_skill_package: {422, "Import a package containing SKILL.md and its files."},
    skill_path_conflict:
      {409, "A file and a directory cannot share a path. Choose another path."},
    invalid_contract: {422, "Select a valid contract slot and inheritance mode."},
    principal_owned_object: {422, "Rename this person or Agent through its identity settings."},
    connection_application_change_requires_new_connection:
      {422,
       "Create a separate connection for a different external application. You can rotate this application's secret here."},
    comment_conflict: {409, "The comment changed. Reload it before trying again."},
    invalid_comment_body: {422, "Enter a comment of at most 20,000 characters."},
    invalid_comment_reply:
      {422, "Replies must belong to an existing root discussion on this page."},
    invalid_comment_anchor:
      {422, "The text anchor must belong to an existing discussion on this page."},
    file_anchor_outdated: {409, "The file changed. Reload it and select the passage again."},
    invalid_comment_quote:
      {422, "Selected quote exceeds the 1,000-character or 4,096-byte limit."},
    interaction_not_pending: {409, "This question has an answer or was superseded"},
    invalid_choice: {422, "Select a valid answer"},
    participant_unavailable: {422, "This participant is unavailable"},
    cannot_remove_last_participant: {422, "The room needs an Agent"},
    anchor_page_required: {422, "Select an anchor page to share this discussion"},
    forbidden_room_operation: {403, "Only the room owner or space administrator can do this"},
    conversation_not_found: {404, "Conversation not found"},
    execution_not_found: {404, "Execution not found in this conversation"},
    execution_already_continued:
      {409, "This background job already continued in a follow-up run"},
    execution_not_continuable:
      {409,
       "This background job ended before starting a workspace session and cannot be continued"},
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
    queue_changed: {409, "The pending queue changed. Reload it before reordering"},
    not_encrypted: {422, "This variable is not encrypted"},
    invalid_worker_env_value: {422, "A non-empty string value is required"},
    invalid_worker_env_secret: {422, "The secret flag must be a boolean"},
    invalid_worker_env_description: {422, "The description must be a string"},
    applet_env_too_large: {413, "Combined Applet environment variables must not exceed 64 KiB"}
  }

  def message(error), do: public_error(error.reason).message

  def public_error({:invalid_worker_env_name, _}),
    do: %{
      code: "invalid_worker_env_name",
      message: "Variable name must match [A-Za-z_][A-Za-z0-9_]*",
      status: 422,
      details: nil
    }

  def public_error({:reserved_worker_env_name, name}),
    do: %{
      code: "reserved_worker_env_name",
      message: "#{name} is reserved by the runtime",
      status: 422,
      details: nil
    }

  def public_error({:blob_missing, _}), do: public_error(:attachment_expired)

  def public_error({:invalid_form_answer, fields}),
    do: %{
      code: "invalid_form_answer",
      message: "Correct the highlighted fields",
      status: 422,
      details: %{fields: fields}
    }

  def public_error(%{code: "oauth_consent_required"} = details),
    do: %{
      code: details.code,
      message:
        "Authorize the account owner to use this connection with the requested permissions.",
      status: 422,
      details: details
    }

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
