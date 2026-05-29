import { RiArrowDownSLine, RiArrowRightSLine, RiArrowUpSLine } from "@remixicon/react"
import type React from "react"
import { useState } from "react"
import { useForm as useHookForm } from "react-hook-form"
import { useTranslation } from "react-i18next"
import { Alert, AlertDescription, AlertTitle } from "@/uikit/components/alert"
import { Badge } from "@/uikit/components/badge"
import { Collapsible, CollapsibleContent, CollapsibleTrigger } from "@/uikit/components/collapsible"
import { Button, ErrorAlert, SetupPage, SetupPanel, submitInertia } from "../shared"

type RouteRule = {
  id?: string
  name?: string
  priority?: number
  match_expr?: string
  target_type?: string
  target_ref?: string
  scope_fields?: string[]
}

type RoutingProjection = {
  "complete?"?: boolean
  state?: string
  reason?: string | null
  source?: {
    adapter_id?: string
    plugin_id?: string
    source_id?: string
    domain?: string
    im_listen_mode?: string
    runtime?: { ready?: boolean }
  } | null
  target?: {
    principal_uid?: string
    uid?: string
    display_name?: string
  } | null
  expected_rule?: RouteRule | null
  live_rule?: RouteRule | null
  conflict_rule?: RouteRule | null
}

export default function SetupEventRoutingApp({
  app_name = "BullX",
  routing,
  form_action,
  back_path,
  error,
}: {
  app_name?: string
  routing?: RoutingProjection
  form_action: string
  back_path: string
  error?: unknown
}) {
  const { t } = useTranslation()
  const { handleSubmit } = useHookForm()

  return (
    <SetupPage title={t("setup.event_routing.page_title")} appName={app_name} step="event_routing">
      <SetupPanel
        title={t("setup.event_routing.panel_title")}
        footer={
          <>
            <Button type="button" variant="outline" onClick={() => window.location.assign(back_path)}>
              {t("setup.back")}
            </Button>
            <Button type="submit" form="setup-routing-form">
              {t("setup.event_routing.save_button")}
              <RiArrowRightSLine data-icon="inline-end" />
            </Button>
          </>
        }>
        <ErrorAlert error={error} />
        <RouteStatus routing={routing} />
        <RouteFlow routing={routing} />
        <RouteDetails routing={routing} />
        <form id="setup-routing-form" onSubmit={handleSubmit(() => submitInertia(form_action, {}))} />
      </SetupPanel>
    </SetupPage>
  )
}

function RouteStatus({ routing }: { routing?: RoutingProjection }) {
  const { t } = useTranslation()
  const state = routeState(routing)
  const tone = stateTone(state)
  const values = routeCopyValues(routing)

  return (
    <Alert variant={tone === "danger" ? "destructive" : "default"}>
      <AlertTitle>{t(`setup.event_routing.states.${state}.title`, { defaultValue: state })}</AlertTitle>
      <AlertDescription>{t(`setup.event_routing.states.${state}.body`, { values })}</AlertDescription>
    </Alert>
  )
}

function RouteFlow({ routing }: { routing?: RoutingProjection }) {
  const { t } = useTranslation()
  const state = routeState(routing)
  const source = routing?.source
  const target = routing?.target

  return (
    <section className="grid grid-cols-1 gap-3 lg:grid-cols-[minmax(0,1fr)_2rem_minmax(0,1.15fr)_2rem_minmax(0,1fr)] lg:items-stretch">
      <RouteNode
        eyebrow={t("setup.event_routing.source_label")}
        title={sourceLabel(source)}
        description={source ? t("setup.event_routing.source_description") : t("setup.event_routing.source_missing")}
        badge={
          source ? (
            <Badge variant={source.runtime?.ready ? "default" : "outline"}>
              {t(source.runtime?.ready ? "setup.event_routing.runtime_ready" : "setup.event_routing.runtime_pending")}
            </Badge>
          ) : null
        }
      />
      <RouteArrow />
      <RouteNode
        eyebrow={t("setup.event_routing.rule_label")}
        title={t("setup.event_routing.rule_default_title")}
        description={t("setup.event_routing.rule_description")}
        badge={<StateBadge state={state} />}
      />
      <RouteArrow />
      <RouteNode
        eyebrow={t("setup.event_routing.target_label")}
        title={targetLabel(target)}
        description={target ? t("setup.event_routing.target_description") : t("setup.event_routing.target_missing")}
        badge={target?.uid ? <Badge variant="outline">@{target.uid}</Badge> : null}
      />
    </section>
  )
}

function RouteNode({
  eyebrow,
  title,
  description,
  badge,
}: {
  eyebrow: string
  title: string
  description: string
  badge?: React.ReactNode
}) {
  return (
    <div className="min-h-32 border border-border/70 bg-muted/20 p-4">
      <div className="flex min-h-6 items-center justify-between gap-3">
        <span className="text-xs font-semibold uppercase text-muted-foreground">{eyebrow}</span>
        {badge}
      </div>
      <div className="mt-3 truncate text-base font-semibold text-foreground">{title}</div>
      <p className="mt-1 text-sm leading-5 text-muted-foreground">{description}</p>
    </div>
  )
}

function RouteArrow() {
  return (
    <div className="hidden items-center justify-center text-muted-foreground lg:flex">
      <RiArrowRightSLine className="size-5" />
    </div>
  )
}

function RouteDetails({ routing }: { routing?: RoutingProjection }) {
  const { t } = useTranslation()
  const [advancedOpen, setAdvancedOpen] = useState(false)
  const state = routeState(routing)
  const source = routing?.source
  const target = routing?.target
  const rule = primaryRule(routing)
  const conflictRule = routing?.conflict_rule

  if (!rule) return null

  return (
    <section className="flex flex-col gap-4 border-t border-border/70 pt-5">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h3 className="text-sm font-semibold uppercase text-muted-foreground">
          {t(
            state === "live" ? "setup.event_routing.route_config_live_title" : "setup.event_routing.route_config_title",
          )}
        </h3>
        <Badge variant="outline">
          {t("setup.event_routing.priority_value", { values: { priority: rule.priority ?? "-" } })}
        </Badge>
      </div>
      <dl className="grid gap-3 md:grid-cols-2">
        <DetailItem label={t("setup.event_routing.route_source_label")} value={sourceLabel(source)} />
        <DetailItem label={t("setup.event_routing.route_match_label")} value={t("setup.event_routing.match_summary")} />
        <DetailItem label={t("setup.event_routing.route_target_label")} value={targetDisplay(target)} />
        <DetailItem
          label={t("setup.event_routing.route_effect_label")}
          value={t("setup.event_routing.route_effect_summary")}
        />
      </dl>
      <Collapsible open={advancedOpen} onOpenChange={setAdvancedOpen}>
        <CollapsibleTrigger
          render={
            <Button type="button" variant="outline" className="w-fit">
              {t("setup.event_routing.advanced_details_label")}
              {advancedOpen ? <RiArrowUpSLine data-icon="inline-end" /> : <RiArrowDownSLine data-icon="inline-end" />}
            </Button>
          }
        />
        <CollapsibleContent className="mt-3">
          <dl className="grid gap-3 md:grid-cols-2">
            <DetailItem label={t("setup.event_routing.rule_name_label")} value={rule.name || "-"} mono />
            <DetailItem label={t("setup.event_routing.match_label")} value={rule.match_expr || "-"} mono />
            <DetailItem label={t("setup.event_routing.target_ref_label")} value={targetRef(rule)} mono />
            <DetailItem label={t("setup.event_routing.scope_fields_label")} value={scopeFields(rule)} mono />
          </dl>
        </CollapsibleContent>
      </Collapsible>
      {conflictRule ? (
        <div className="border border-destructive/50 bg-destructive/10 p-4">
          <p className="text-sm font-semibold">{t("setup.event_routing.conflict_rule_title")}</p>
          <p className="mt-2 font-mono text-sm break-all text-muted-foreground">{conflictRule.name || "-"}</p>
        </div>
      ) : null}
    </section>
  )
}

function DetailItem({ label, value, mono }: { label: string; value: string; mono?: boolean }) {
  return (
    <div className="min-w-0 border border-border/70 bg-background/60 p-3">
      <dt className="text-xs font-semibold uppercase text-muted-foreground">{label}</dt>
      <dd className={["mt-1 text-sm break-words text-foreground", mono ? "font-mono" : ""].filter(Boolean).join(" ")}>
        {value}
      </dd>
    </div>
  )
}

function StateBadge({ state }: { state: string }) {
  const { t } = useTranslation()
  const variant = stateTone(state) === "danger" ? "destructive" : state === "live" ? "default" : "secondary"

  return <Badge variant={variant}>{t(`setup.event_routing.state_badges.${state}`, { defaultValue: state })}</Badge>
}

function routeState(routing?: RoutingProjection) {
  if (routing?.state) return routing.state
  return routing?.["complete?"] ? "live" : "missing"
}

function stateTone(state: string) {
  return ["conflict", "target_mismatch", "error"].includes(state) ? "danger" : "default"
}

function primaryRule(routing?: RoutingProjection) {
  return routing?.live_rule || routing?.expected_rule || null
}

function routeCopyValues(routing?: RoutingProjection) {
  const rule = primaryRule(routing)

  return {
    source: sourceLabel(routing?.source),
    target: targetLabel(routing?.target),
    rule: rule?.name || "-",
    priority: rule?.priority ?? "-",
  }
}

function sourceLabel(source: RoutingProjection["source"] | undefined) {
  if (!source) return "-"
  return [formatDisplayId(source.adapter_id), source.source_id].filter(Boolean).join(" / ") || "-"
}

function targetLabel(target: RoutingProjection["target"] | undefined) {
  if (!target) return "-"
  return target.display_name || (target.uid ? `@${target.uid}` : target.principal_uid || "-")
}

function targetDisplay(target: RoutingProjection["target"] | undefined) {
  if (!target) return "-"
  const label = targetLabel(target)
  return target.uid && label !== `@${target.uid}` ? `${label} (@${target.uid})` : label
}

function targetRef(rule: RouteRule) {
  return [rule.target_type, rule.target_ref].filter(Boolean).join(" / ") || "-"
}

function scopeFields(rule: RouteRule) {
  return rule.scope_fields?.length ? rule.scope_fields.join(", ") : "-"
}

function formatDisplayId(value?: string) {
  if (!value) return undefined
  if (value === "feishu") return "Feishu"
  return value
}
