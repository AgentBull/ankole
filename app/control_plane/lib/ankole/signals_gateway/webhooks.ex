defmodule Ankole.SignalsGateway.Webhooks do
  @moduledoc """
  Owns webhook capability URLs and their durable consumer handoff.

  A capability URL authorizes one delivery only. It does not authenticate the
  facts in the request body. An Agent or bound automation job must verify those
  facts through the external system before it makes a consequential change.
  """

  import Ecto.Query, warn: false

  alias Ankole.AutomationJobs
  alias Ankole.AutomationJobs.Schemas.Run, as: AutomationJobRun
  alias Ankole.Ecto.UUIDv7
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.WebhookEndpoint

  @active_statuses ~w(armed active)
  @token_pattern ~r/\Awh_[A-Za-z0-9_-]{43}\z/

  @type receive_result ::
          {:ok,
           %{
             optional(:actor_event) => Ankole.SignalsGateway.ActorEvent.t(),
             optional(:automation_job_run) => AutomationJobRun.t(),
             status: :accepted | :ignored,
             webhook_endpoint: WebhookEndpoint.t()
           }}
          | {:error, term()}

  @doc """
  Creates one webhook endpoint and keeps the plaintext token outside PostgreSQL.
  """
  @spec create_endpoint(map(), String.t(), keyword()) ::
          {:ok,
           %{
             status: :created | :already_exists,
             webhook_endpoint: WebhookEndpoint.t()
           }}
          | {:error, term()}
  def create_endpoint(attrs, token, opts \\ [])

  def create_endpoint(attrs, token, opts) when is_map(attrs) and is_binary(token) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    with :ok <- validate_token(token),
         {:ok, attrs} <- create_attrs(attrs, token),
         :ok <- validate_expiry(attrs, now) do
      Repo.transact(fn repo ->
        with :ok <-
               AutomationJobs.validate_bindable_in_tx(
                 repo,
                 Map.get(attrs, "automation_job_id"),
                 Map.fetch!(attrs, "agent_uid"),
                 now
               ) do
          changeset = WebhookEndpoint.changeset(%WebhookEndpoint{}, attrs)

          case repo.insert(changeset, mode: :savepoint) do
            {:ok, endpoint} ->
              {:ok, %{status: :created, webhook_endpoint: endpoint}}

            {:error, %Ecto.Changeset{} = changeset} ->
              existing_or_error(repo, changeset, attrs)
          end
        end
      end)
    end
  end

  def create_endpoint(_attrs, _token, _opts), do: {:error, :invalid_webhook_endpoint}

  @doc """
  Lists webhook endpoints for one Agent session, for every session of the
  Agent when `session_id` is `nil`, or across every Agent when `agent_uid` is
  also `nil`.

  Active-only lists exclude endpoints whose expiry time has already passed,
  even if the periodic sweep has not updated their stored status yet.
  """
  @spec list_endpoints(String.t() | nil, String.t() | nil, keyword()) :: [WebhookEndpoint.t()]
  def list_endpoints(agent_uid, session_id, opts \\ [])
      when (is_binary(agent_uid) or is_nil(agent_uid)) and
             (is_binary(session_id) or is_nil(session_id)) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
    limit = opts |> Keyword.get(:limit, 100) |> bounded_limit()

    WebhookEndpoint
    |> maybe_where_agent(agent_uid)
    |> maybe_where_session(session_id)
    |> maybe_active_only(Keyword.get(opts, :active_only, false), now)
    |> order_by([endpoint], desc: endpoint.inserted_at, desc: endpoint.id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Gets one endpoint only when it belongs to the specified Agent session.
  """
  @spec get_endpoint_for_session(String.t(), String.t(), Ecto.UUID.t()) ::
          {:ok, WebhookEndpoint.t()} | {:error, :webhook_endpoint_not_found}
  def get_endpoint_for_session(agent_uid, session_id, endpoint_id)
      when is_binary(agent_uid) and is_binary(session_id) and is_binary(endpoint_id) do
    case Repo.get_by(WebhookEndpoint,
           id: endpoint_id,
           agent_uid: String.downcase(agent_uid),
           session_id: session_id
         ) do
      %WebhookEndpoint{} = endpoint -> {:ok, endpoint}
      nil -> {:error, :webhook_endpoint_not_found}
    end
  end

  def get_endpoint_for_session(_agent_uid, _session_id, _endpoint_id),
    do: {:error, :webhook_endpoint_not_found}

  @doc """
  Cancels an active endpoint. Repeating the operation keeps the terminal state.

  A `nil` `session_id` accepts any session of the Agent.
  """
  @spec cancel_endpoint(String.t(), String.t() | nil, Ecto.UUID.t(), keyword()) ::
          {:ok,
           %{
             status: :cancelled | :already_terminal,
             webhook_endpoint: WebhookEndpoint.t()
           }}
          | {:error, term()}
  def cancel_endpoint(agent_uid, session_id, endpoint_id, opts \\ [])

  def cancel_endpoint(agent_uid, session_id, endpoint_id, opts)
      when is_binary(agent_uid) and (is_binary(session_id) or is_nil(session_id)) and
             is_binary(endpoint_id) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      case lock_endpoint(repo, endpoint_id, String.downcase(agent_uid), session_id) do
        %WebhookEndpoint{} = endpoint ->
          cancel_locked_endpoint(repo, endpoint, now)

        nil ->
          {:error, :webhook_endpoint_not_found}
      end
    end)
  end

  def cancel_endpoint(_agent_uid, _session_id, _endpoint_id, _opts),
    do: {:error, :webhook_endpoint_not_found}

  @doc """
  Accepts one callback and stores its ActorEvent or automation job run in the
  same transaction.
  """
  @spec receive(String.t(), [{String.t(), String.t()}], binary(), keyword()) :: receive_result()
  def receive(token, headers, body, opts \\ [])

  def receive(token, headers, body, opts)
      when is_binary(token) and is_list(headers) and is_binary(body) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    with :ok <- validate_token(token) do
      Repo.transact(fn repo ->
        case lock_endpoint_by_token(repo, token) do
          %WebhookEndpoint{} = endpoint -> receive_locked(repo, endpoint, headers, body, now)
          nil -> {:error, :webhook_endpoint_not_found}
        end
      end)
    else
      {:error, :invalid_webhook_token} -> {:error, :webhook_endpoint_not_found}
    end
  end

  def receive(_token, _headers, _body, _opts), do: {:error, :webhook_endpoint_not_found}

  @doc """
  Keeps only callback headers that carry event metadata.

  Authentication and general HTTP headers are deliberately discarded.
  """
  @spec allowlisted_headers([{String.t(), String.t()}]) :: map()
  def allowlisted_headers(headers) when is_list(headers) do
    headers
    |> Enum.reduce(%{}, fn
      {name, value}, acc when is_binary(name) and is_binary(value) ->
        name = String.downcase(name)

        if allowlisted_header?(name) and durable_text?(value) do
          Map.update(acc, name, value, &(&1 <> ", " <> value))
        else
          acc
        end

      _header, acc ->
        acc
    end)
  end

  @doc """
  Marks due active endpoints as expired and returns the number changed.
  """
  @spec expire_due(DateTime.t()) :: non_neg_integer()
  def expire_due(%DateTime{} = now) do
    {count, _rows} =
      WebhookEndpoint
      |> where(
        [endpoint],
        endpoint.status in ^@active_statuses and endpoint.expires_at <= ^now
      )
      |> Repo.update_all(set: [status: "expired", updated_at: now])

    count
  end

  @doc """
  Returns the Console-safe endpoint projection.
  """
  @spec console_projection(WebhookEndpoint.t()) :: map()
  def console_projection(%WebhookEndpoint{} = endpoint) do
    %{
      id: endpoint.id,
      agent_uid: endpoint.agent_uid,
      binding_name: endpoint.binding_name,
      session_id: endpoint.session_id,
      signal_channel_id: endpoint.signal_channel_id,
      provider_thread_id: endpoint.provider_thread_id,
      source_actor_event_id: endpoint.source_actor_event_id,
      source_entry_id: endpoint.source_entry_id,
      source_provenance: endpoint.source_provenance || %{},
      automation_job_id: endpoint.automation_job_id,
      label: endpoint.label,
      mode: endpoint.mode,
      status: endpoint.status,
      expires_at: iso8601(endpoint.expires_at),
      fired_at: iso8601(endpoint.fired_at),
      cancelled_at: iso8601(endpoint.cancelled_at),
      created_at: iso8601(endpoint.inserted_at),
      updated_at: iso8601(endpoint.updated_at)
    }
  end

  @doc """
  Returns the model-safe endpoint projection.
  """
  @spec model_projection(WebhookEndpoint.t()) :: map()
  def model_projection(%WebhookEndpoint{} = endpoint) do
    %{
      "id" => endpoint.id,
      "label" => endpoint.label,
      "mode" => endpoint.mode,
      "status" => endpoint.status,
      "automation_job_id" => endpoint.automation_job_id,
      "expires_at" => iso8601(endpoint.expires_at),
      "created_at" => iso8601(endpoint.inserted_at)
    }
  end

  @doc """
  Calculates the digest stored for one plaintext callback token.
  """
  @spec token_digest(String.t()) :: String.t()
  def token_digest(token) when is_binary(token) do
    token
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  defp create_attrs(attrs, token) do
    attrs = stringify_keys(attrs)
    mode = Map.get(attrs, "mode")

    status =
      case mode do
        "one_shot" -> "armed"
        "standing" -> "active"
        _mode -> nil
      end

    {:ok,
     attrs
     |> Map.put("agent_uid", attrs |> Map.get("agent_uid") |> normalize_agent_uid())
     |> Map.put("token_digest", token_digest(token))
     |> Map.put("status", status)}
  end

  defp validate_expiry(%{"expires_at" => %DateTime{} = expires_at}, %DateTime{} = now) do
    if DateTime.compare(expires_at, now) == :gt,
      do: :ok,
      else: {:error, :webhook_expiry_must_be_future}
  end

  defp validate_expiry(_attrs, _now), do: {:error, :invalid_webhook_expiry}

  defp existing_or_error(repo, changeset, attrs) do
    if changeset_error_on?(changeset, :token_digest) do
      case repo.get_by(WebhookEndpoint, token_digest: Map.fetch!(attrs, "token_digest")) do
        %WebhookEndpoint{} = endpoint ->
          if same_endpoint?(endpoint, attrs) do
            {:ok, %{status: :already_exists, webhook_endpoint: endpoint}}
          else
            {:error, :webhook_token_collision}
          end

        nil ->
          {:error, changeset}
      end
    else
      {:error, changeset}
    end
  end

  defp same_endpoint?(endpoint, attrs) do
    fields =
      ~w(agent_uid binding_name session_id signal_channel_id provider_thread_id source_actor_event_id source_entry_id label mode expires_at automation_job_id)

    Enum.all?(fields, fn field ->
      same_endpoint_value?(field, Map.get(attrs, field), endpoint_value(endpoint, field))
    end)
  end

  defp same_endpoint_value?("expires_at", %DateTime{} = left, %DateTime{} = right),
    do: DateTime.compare(left, right) == :eq

  defp same_endpoint_value?(_field, left, right), do: left == right

  defp endpoint_value(endpoint, "agent_uid"), do: endpoint.agent_uid
  defp endpoint_value(endpoint, "binding_name"), do: endpoint.binding_name
  defp endpoint_value(endpoint, "session_id"), do: endpoint.session_id
  defp endpoint_value(endpoint, "signal_channel_id"), do: endpoint.signal_channel_id
  defp endpoint_value(endpoint, "provider_thread_id"), do: endpoint.provider_thread_id
  defp endpoint_value(endpoint, "source_actor_event_id"), do: endpoint.source_actor_event_id
  defp endpoint_value(endpoint, "source_entry_id"), do: endpoint.source_entry_id
  defp endpoint_value(endpoint, "label"), do: endpoint.label
  defp endpoint_value(endpoint, "mode"), do: endpoint.mode
  defp endpoint_value(endpoint, "expires_at"), do: endpoint.expires_at
  defp endpoint_value(endpoint, "automation_job_id"), do: endpoint.automation_job_id

  defp cancel_locked_endpoint(repo, endpoint, now) do
    cond do
      endpoint.status not in @active_statuses ->
        {:ok, %{status: :already_terminal, webhook_endpoint: endpoint}}

      DateTime.compare(endpoint.expires_at, now) != :gt ->
        with {:ok, expired} <- update_status(repo, endpoint, "expired") do
          {:ok, %{status: :already_terminal, webhook_endpoint: expired}}
        end

      true ->
        with {:ok, cancelled} <-
               endpoint
               |> WebhookEndpoint.changeset(%{
                 status: "cancelled",
                 cancelled_at: now
               })
               |> repo.update() do
          {:ok, %{status: :cancelled, webhook_endpoint: cancelled}}
        end
    end
  end

  defp receive_locked(repo, endpoint, headers, body, now) do
    cond do
      endpoint.status not in @active_statuses ->
        {:ok, %{status: :ignored, webhook_endpoint: endpoint}}

      DateTime.compare(endpoint.expires_at, now) != :gt ->
        with {:ok, expired} <- update_status(repo, endpoint, "expired") do
          {:ok, %{status: :ignored, webhook_endpoint: expired}}
        end

      true ->
        append_receipt(repo, endpoint, headers, body, now)
    end
  end

  defp append_receipt(repo, endpoint, headers, body, now) do
    source_event_id = "webhook:#{endpoint.id}:#{UUIDv7.autogenerate()}"
    payload = receipt_payload(endpoint, source_event_id, headers, body, now)

    with {:ok, delivery} <- deliver_receipt(repo, endpoint, source_event_id, payload, now),
         {:ok, endpoint} <- maybe_mark_fired(repo, endpoint, now) do
      {:ok, receipt_result(endpoint, delivery)}
    end
  end

  defp deliver_receipt(
         repo,
         %WebhookEndpoint{automation_job_id: nil} = endpoint,
         source_event_id,
         payload,
         now
       ) do
    with {:ok, actor_event} <-
           SignalsGateway.append_actor_event_in_tx(
             repo,
             receipt_actor_attrs(endpoint, source_event_id, payload, now)
           ) do
      {:ok, {:actor_event, actor_event}}
    end
  end

  defp deliver_receipt(
         repo,
         %WebhookEndpoint{automation_job_id: automation_job_id} = endpoint,
         _source_event_id,
         payload,
         now
       ) do
    with {:ok, %{automation_job_run: run}} <-
           AutomationJobs.enqueue_run_in_tx(
             repo,
             automation_job_id,
             endpoint.agent_uid,
             payload,
             now: now
           ) do
      {:ok, {:automation_job_run, run}}
    end
  end

  defp receipt_actor_attrs(endpoint, source_event_id, payload, now) do
    %{
      agent_uid: endpoint.agent_uid,
      binding_name: endpoint.binding_name,
      session_id: endpoint.session_id,
      source_event_id: source_event_id,
      signal_channel_id: endpoint.signal_channel_id,
      provider_thread_id: endpoint.provider_thread_id,
      source_entry_id: endpoint.source_entry_id,
      type: "webhook.received",
      available_at: now,
      sender_key: nil,
      payload: payload
    }
  end

  defp receipt_result(endpoint, {:actor_event, actor_event}) do
    %{status: :accepted, webhook_endpoint: endpoint, actor_event: actor_event}
  end

  defp receipt_result(endpoint, {:automation_job_run, run}) do
    %{status: :accepted, webhook_endpoint: endpoint, automation_job_run: run}
  end

  defp receipt_payload(endpoint, source_event_id, headers, body, now) do
    {encoded_body, encoding} = encode_body(body)

    %{
      "specversion" => "1.0",
      "id" => source_event_id,
      "source" => "control-plane://signals-gateway/webhooks",
      "subject" => "webhook_endpoint:#{endpoint.id}",
      "time" => DateTime.to_iso8601(now),
      "type" => "webhook.received",
      "data" => %{
        "webhook_endpoint" => %{
          "id" => endpoint.id,
          "label" => endpoint.label,
          "mode" => endpoint.mode
        },
        "headers" => allowlisted_headers(headers),
        "body" => encoded_body,
        "body_encoding" => encoding,
        "body_size" => byte_size(body),
        "received_at" => DateTime.to_iso8601(now),
        "reply_route" =>
          reject_nil_values(%{
            "binding_name" => endpoint.binding_name,
            "signal_channel_id" => endpoint.signal_channel_id,
            "provider_thread_id" => endpoint.provider_thread_id,
            "source_entry_id" => endpoint.source_entry_id
          }),
        "source_actor_event_id" => endpoint.source_actor_event_id,
        "source_provenance" => endpoint.source_provenance || %{}
      }
    }
  end

  defp maybe_mark_fired(repo, %WebhookEndpoint{mode: "one_shot"} = endpoint, now) do
    endpoint
    |> WebhookEndpoint.changeset(%{status: "fired", fired_at: now})
    |> repo.update()
  end

  defp maybe_mark_fired(_repo, %WebhookEndpoint{mode: "standing"} = endpoint, _now),
    do: {:ok, endpoint}

  defp update_status(repo, endpoint, status) do
    endpoint
    |> WebhookEndpoint.changeset(%{status: status})
    |> repo.update()
  end

  defp lock_endpoint(repo, endpoint_id, agent_uid, session_id) do
    WebhookEndpoint
    |> where([endpoint], endpoint.id == ^endpoint_id and endpoint.agent_uid == ^agent_uid)
    |> maybe_where_session(session_id)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp lock_endpoint_by_token(repo, token) do
    digest = token_digest(token)

    WebhookEndpoint
    |> where([endpoint], endpoint.token_digest == ^digest)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp maybe_where_agent(query, nil), do: query

  defp maybe_where_agent(query, agent_uid),
    do: where(query, [endpoint], endpoint.agent_uid == ^String.downcase(agent_uid))

  defp maybe_where_session(query, nil), do: query

  defp maybe_where_session(query, session_id),
    do: where(query, [endpoint], endpoint.session_id == ^session_id)

  defp maybe_active_only(query, false, _now), do: query

  defp maybe_active_only(query, true, now) do
    where(
      query,
      [endpoint],
      endpoint.status in ^@active_statuses and endpoint.expires_at > ^now
    )
  end

  defp allowlisted_header?("content-type"), do: true
  defp allowlisted_header?("x-hub-signature-256"), do: true
  defp allowlisted_header?("ce-" <> _name), do: true
  defp allowlisted_header?("x-github-" <> _name), do: true
  defp allowlisted_header?(_name), do: false

  defp encode_body(body) do
    if durable_text?(body),
      do: {body, "utf-8"},
      else: {Base.encode64(body), "base64"}
  end

  defp durable_text?(value),
    do: String.valid?(value) and :binary.match(value, <<0>>) == :nomatch

  defp validate_token(token) do
    if Regex.match?(@token_pattern, token),
      do: :ok,
      else: {:error, :invalid_webhook_token}
  end

  defp changeset_error_on?(changeset, field) do
    Enum.any?(changeset.errors, fn {error_field, _error} -> error_field == field end)
  end

  defp bounded_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, 500)
  defp bounded_limit(_limit), do: 100

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp normalize_agent_uid(value) when is_binary(value), do: String.downcase(value)
  defp normalize_agent_uid(value), do: value

  defp reject_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(_value), do: nil
end
