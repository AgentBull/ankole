defmodule Ankole.Plugins.CloudConnectorsAdapter.Definitions do
  @moduledoc false

  @platforms [
    {"gitlab", "GitLab", "GitLab", "project_id",
     ~w(merge_request.updated push issue.updated pipeline.completed)},
    {"typeform", "Typeform", "Typeform", "form_id", ~w(form_response.submitted)},
    {"salesforce", "Salesforce", "Salesforce", "object", ~w(record.created record.updated)},
    {"trello", "Trello", "Trello", "board_id", ~w(card.created card.updated card.moved)},
    {"calendly", "Calendly", "Calendly", "Organization URI",
     ~w(invitee.created invitee.canceled)},
    {"google_analytics", "GoogleAnalytics", "Google Analytics", nil, []},
    {"googlecalendar", "GoogleCalendar", "Google Calendar", "calendar_id",
     ~w(event.created event.updated event.canceled)},
    {"stripe", "Stripe", "Stripe", "account",
     ~w(checkout.session.completed invoice.paid payment_intent.succeeded)},
    {"sentry", "Sentry", "Sentry", "Project ID or slug", ~w(issue.created error.alert_triggered)},
    {"zendesk", "Zendesk", "Zendesk", "subdomain", ~w(ticket.created ticket.updated)},
    {"figma", "Figma", "Figma", "File, folder, or team ID",
     ~w(file.updated file_comment.created library.published)}
  ]

  def platforms, do: @platforms
  def oauth?(id), do: id not in ~w(stripe sentry zendesk figma)

  def module(id),
    do:
      Enum.find_value(@platforms, fn {key, name, _, _, _} ->
        if id == key, do: Module.concat(Ankole.Plugins.CloudConnectorsAdapter, name)
      end)

  def declarations do
    Enum.map(@platforms, fn {id, _, label, scope, events} ->
      %{
        contract_id: "connectors.connector",
        id: id,
        plugin_id: "cloud-connectors-adapter",
        module: module(id),
        display_name: %{"default" => label},
        auth_schemes: [scheme(id)],
        personal_credentials: id == "figma",
        personal_credential_fields: if(id == "figma", do: credentials(id), else: []),
        credential_fields: if(oauth?(id), do: oauth_fields(), else: credentials(id)),
        public_fields: public_fields(id),
        trigger_types:
          Enum.map(events, fn event ->
            %{
              id: id <> "." <> event,
              label: event,
              fixed_scope_key: if(id in ~w(stripe zendesk), do: "account"),
              scope_label:
                if(id == "salesforce" and event == "record.created",
                  do: "Lead or Contact",
                  else: scope
                ),
              scope_options:
                if(id == "salesforce" and event == "record.created",
                  do: ["Lead", "Contact"],
                  else: []
                ),
              requires_personal_account: false,
              supports_personal_account: oauth?(id) or id == "figma",
              data_schema: Ankole.Plugins.CloudConnectorsAdapter.Events.schema(),
              oauth_scopes: trigger_scopes(id),
              config_fields: trigger_fields(id)
            }
          end),
        event_streams: []
      }
    end)
  end

  def scheme("figma"), do: "personal_token"
  def scheme(id) when id in ~w(stripe sentry zendesk), do: "api_token"
  def scheme(_), do: "oauth2"

  defp oauth_fields,
    do: [
      field("clientID", "OAuth client ID", false),
      field("clientSecret", "OAuth client secret", true)
    ]

  defp credentials("zendesk"),
    do: [
      field("subdomain", "Zendesk subdomain", false),
      field("email", "Administrator email", false),
      field("api_token", "API token", true)
    ]

  defp credentials("sentry"),
    do: [
      field("access_token", "Access token", true),
      Map.put(
        field("webhook_secret", "Internal Integration client secret (for events)", true),
        :required,
        false
      )
    ]

  defp credentials(_), do: [field("access_token", "Access token", true)]
  defp field(key, label, secret), do: %{key: key, label: label, secret: secret, required: true}

  defp public_fields(id) when id in ~w(gitlab sentry salesforce),
    do: [%{key: "base_url", label: "Platform URL", required: false}]

  defp public_fields(_), do: []

  defp trigger_fields("calendly") do
    [
      %{
        path: "scope",
        type: :select,
        required: true,
        default: "user",
        label: text("Receive events for", "接收谁的事件", "イベントの対象", "이벤트 수신 범위"),
        description:
          text(
            "Personal subscriptions use the connected account. Organization subscriptions require a Calendly owner or administrator. Enter the full organization URI, such as https://api.calendly.com/organizations/….",
            "默认只接收当前连接账号的事件。订阅整个组织需要 Calendly 所有者或管理员权限。请填写完整组织 URI，例如 https://api.calendly.com/organizations/…。",
            "個人の購読では接続中のアカウントを使用します。組織全体の購読には Calendly の所有者または管理者権限が必要です。https://api.calendly.com/organizations/… の形式で組織 URI を入力してください。",
            "개인 구독은 연결된 계정을 사용합니다. 조직 전체를 구독하려면 Calendly 소유자 또는 관리자 권한이 필요합니다. https://api.calendly.com/organizations/… 형식의 전체 조직 URI를 입력하세요."
          ),
        options: [
          %{value: "user", label: text("My events", "仅本人", "自分のイベント", "내 이벤트")},
          %{value: "organization", label: text("Entire organization", "整个组织", "組織全体", "전체 조직")}
        ]
      }
    ]
  end

  defp trigger_fields("figma") do
    [
      %{
        path: "context",
        type: :select,
        required: true,
        default: "file",
        label: text("Resource type", "资源类型", "リソースの種類", "리소스 유형"),
        description:
          text(
            "Choose the resource that the ID identifies. Files and folders require edit permission; teams require administrator permission. The token needs webhooks:read and webhooks:write.",
            "选择与所填 ID 对应的资源类型。文件和文件夹需要编辑权限，团队需要管理员权限。令牌需包含 webhooks:read 和 webhooks:write。",
            "入力した ID に対応する種類を選んでください。ファイルとフォルダーには編集権限、チームには管理者権限が必要です。トークンには webhooks:read と webhooks:write が必要です。",
            "입력한 ID에 해당하는 리소스 유형을 선택하세요. 파일과 폴더에는 편집 권한이, 팀에는 관리자 권한이 필요합니다. 토큰에 webhooks:read 및 webhooks:write 권한이 있어야 합니다."
          ),
        options: [
          %{value: "file", label: text("File", "文件", "ファイル", "파일")},
          %{value: "project", label: text("Folder", "文件夹", "フォルダー", "폴더")},
          %{value: "team", label: text("Team", "团队", "チーム", "팀")}
        ]
      }
    ]
  end

  defp trigger_fields(_), do: []

  defp text(default, chinese, japanese, korean),
    do: %{"default" => default, "zh-Hans-CN" => chinese, "ja-JP" => japanese, "ko-KR" => korean}

  defp trigger_scopes("gitlab"), do: ["api"]
  defp trigger_scopes("typeform"), do: ~w(forms:read webhooks:write)
  defp trigger_scopes("calendly"), do: ~w(scheduled_events:read webhooks:write)
  defp trigger_scopes("trello"), do: ["read:board:trello"]

  defp trigger_scopes("googlecalendar"),
    do: ["https://www.googleapis.com/auth/calendar.events.readonly"]

  defp trigger_scopes("salesforce"), do: ~w(api refresh_token)
  defp trigger_scopes(_), do: []
end
