import { RiArrowLeftLine, RiCheckboxCircleLine, RiFileCopyLine, RiShieldUserLine, RiTimeLine } from "@remixicon/react"
import { QueryClient, QueryClientProvider, useQuery } from "@tanstack/react-query"
import type { ReactNode } from "react"
import { useEffect } from "react"
import { useTranslation } from "react-i18next"
import { Button, InfoAlert, SetupPage, SetupPanel } from "./shared"

const queryClient = new QueryClient()

export default function SetupActivateAdmin(props: ActivateProps) {
  return (
    <QueryClientProvider client={queryClient}>
      <ActivateAdminInner {...props} />
    </QueryClientProvider>
  )
}

type ActivateProps = {
  app_name?: string
  activation_code?: string | null
  command?: string | null
  ready_sources?: ReadySource[]
  status_path: string
  back_path: string
}

type ActivationStatus = {
  activated?: boolean
  handoff?: "pending" | string
  redirect_to?: string
}

type ReadySource = {
  adapter_id?: string
  plugin_id?: string
  source_id?: string
  source?: Record<string, unknown>
}

type SourceRow = [label: string, value: ReactNode]

function ActivateAdminInner({
  app_name = "BullX",
  activation_code,
  command,
  ready_sources = [],
  status_path,
  back_path,
}: ActivateProps) {
  const { t } = useTranslation()
  const activationCommand = command || (activation_code ? `/preauth ${activation_code}` : null)
  const { data, isFetching } = useQuery<ActivationStatus>({
    queryKey: ["setup-activation-status", status_path],
    queryFn: async () => {
      const response = await fetch(status_path, { credentials: "same-origin" })
      return response.json()
    },
    refetchInterval: 5000,
  })

  useEffect(() => {
    if (data?.activated) {
      window.location.assign(data.redirect_to || "/")
    }
  }, [data])

  return (
    <SetupPage title={t("setup.activate_admin.page_title")} appName={app_name} step="activate_admin">
      <SetupPanel
        title={t("setup.activate_admin.panel_title")}
        footer={
          <Button type="button" variant="outline" onClick={() => window.location.assign(back_path)}>
            <RiArrowLeftLine data-icon="inline-start" />
            {t("setup.back")}
          </Button>
        }>
        <p className="max-w-3xl text-sm leading-6 text-muted-foreground">{t("setup.activate_admin.instructions")}</p>
        {activationCommand ? (
          <CommandBox command={activationCommand} />
        ) : (
          <InfoAlert title={t("setup.activate_admin.unavailable_title")}>
            {t("setup.activate_admin.unavailable_body")}
          </InfoAlert>
        )}
        <ActivationStatusPanel status={data} checking={isFetching} />
        <ReadySourcesPanel sources={ready_sources} />
      </SetupPanel>
    </SetupPage>
  )
}

function CommandBox({ command }: { command: string }) {
  const { t } = useTranslation()

  return (
    <section className="border border-border/70 bg-card/60 p-4">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0 flex-1">
          <p className="text-xs font-semibold uppercase text-muted-foreground">
            {t("setup.activate_admin.command_label")}
          </p>
          <pre className="mt-2 max-w-full overflow-auto font-mono text-lg leading-7">{command}</pre>
        </div>
        <Button type="button" size="sm" onClick={() => copy(command)}>
          <RiFileCopyLine data-icon="inline-start" />
          {t("setup.activate_admin.copy_command_button")}
        </Button>
      </div>
    </section>
  )
}

function ActivationStatusPanel({ status, checking }: { status?: ActivationStatus; checking: boolean }) {
  const { t } = useTranslation()
  const activated = status?.activated === true
  const handoffPending = status?.handoff === "pending"

  const icon = activated ? <RiCheckboxCircleLine /> : handoffPending ? <RiShieldUserLine /> : <RiTimeLine />
  const title = activated
    ? t("setup.activate_admin.activated_title")
    : handoffPending
      ? t("setup.activate_admin.handoff_pending_title")
      : t("setup.activate_admin.waiting_title")
  const body = activated
    ? t("setup.activate_admin.activated_body")
    : handoffPending
      ? t("setup.activate_admin.handoff_pending_body")
      : t("setup.activate_admin.waiting_body")

  return (
    <section className="border border-border/70 bg-background/60 p-4">
      <div className="flex items-start gap-3">
        <span className="mt-0.5 text-primary [&_svg]:size-5">{icon}</span>
        <div className="min-w-0 flex-1">
          <div className="flex flex-wrap items-center gap-x-3 gap-y-1">
            <p className="font-semibold">{title}</p>
            {checking ? (
              <span className="text-xs font-medium uppercase text-muted-foreground">
                {t("setup.activate_admin.checking_label")}
              </span>
            ) : null}
          </div>
          <p className="mt-1 text-sm leading-6 text-muted-foreground">{body}</p>
        </div>
      </div>
    </section>
  )
}

function ReadySourcesPanel({ sources }: { sources: ReadySource[] }) {
  const { t } = useTranslation()

  if (sources.length === 0) {
    return (
      <InfoAlert title={t("setup.activate_admin.no_source_title")}>
        {t("setup.activate_admin.no_source_body")}
      </InfoAlert>
    )
  }

  return (
    <section className="grid gap-3">
      <div>
        <p className="text-sm font-semibold">{t("setup.activate_admin.configured_source_title")}</p>
        <p className="mt-1 text-sm leading-6 text-muted-foreground">
          {t("setup.activate_admin.configured_source_body")}
        </p>
      </div>
      <div className="grid gap-3 md:grid-cols-2">
        {sources.map((source, index) => (
          <SourceSummary key={sourceKey(source) || `source-${index}`} source={source} />
        ))}
      </div>
    </section>
  )
}

function SourceSummary({ source }: { source: ReadySource }) {
  const { t } = useTranslation()
  const config = source.source || {}
  const runtime = readRecord(config, "runtime")
  const webLoginDisabled = readBoolean(config, "web_login_disabled")
  const title = readString(config, "id") || source.source_id || source.adapter_id || t("setup.activate_admin.unknown")
  const rows = compactRows([
    [t("setup.activate_admin.source_domain_label"), readString(config, "domain")],
    [t("setup.activate_admin.source_adapter_label"), source.adapter_id],
    [t("setup.activate_admin.source_transport_label"), readString(runtime, "transport")],
    [t("setup.activate_admin.source_listen_mode_label"), readString(config, "im_listen_mode")],
    [
      t("setup.activate_admin.source_login_label"),
      webLoginDisabled === undefined
        ? undefined
        : webLoginDisabled
          ? t("setup.activate_admin.web_login_disabled")
          : t("setup.activate_admin.web_login_enabled"),
    ],
  ])

  return (
    <article className="border border-border/70 bg-card/40 p-4">
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <p className="truncate font-mono text-sm font-semibold">{title}</p>
          <p className="mt-1 text-xs uppercase text-muted-foreground">{source.plugin_id || source.adapter_id}</p>
        </div>
        <span className="shrink-0 border border-primary/50 px-2 py-1 text-xs font-medium text-primary">
          {t("setup.activate_admin.source_ready_label")}
        </span>
      </div>
      <dl className="mt-4 grid gap-2 text-sm">
        {rows.map(([label, value]) => (
          <div key={label} className="grid grid-cols-[8rem_minmax(0,1fr)] gap-3">
            <dt className="text-muted-foreground">{label}</dt>
            <dd className="min-w-0 truncate">{value}</dd>
          </div>
        ))}
      </dl>
    </article>
  )
}

function copy(value: string) {
  if (value && navigator.clipboard) {
    void navigator.clipboard.writeText(value)
  }
}

function sourceKey(source: ReadySource) {
  return [source.adapter_id, source.source_id, readString(source.source || {}, "id")].filter(Boolean).join(":")
}

function compactRows(rows: Array<[string, ReactNode | undefined]>): SourceRow[] {
  return rows.filter((row): row is SourceRow => row[1] !== undefined && row[1] !== "")
}

function readRecord(record: Record<string, unknown>, key: string): Record<string, unknown> {
  const value = record[key]
  return isRecord(value) ? value : {}
}

function readString(record: Record<string, unknown>, key: string): string | undefined {
  const value = record[key]
  return typeof value === "string" && value.length > 0 ? value : undefined
}

function readBoolean(record: Record<string, unknown>, key: string): boolean | undefined {
  const value = record[key]
  return typeof value === "boolean" ? value : undefined
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}
