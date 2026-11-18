import {
  AlertRegular,
  ArrowRoutingRegular,
  BoardRegular,
  BranchRegular,
  CodeRegular,
  DocumentBulletListRegular,
  FolderRegular,
  GlobeRegular,
  HistoryRegular,
  KeyRegular,
  PeopleRegular,
  ScalesRegular,
  ServerRegular,
  SettingsRegular,
  type IconComponent
} from '@ankole/uikit/icons'
import { defineWebappModule, type EditionWebappModule } from '../../common/slots'
import { DeclarativeRoutedPage } from './resources'
import { useDeclarativeVisibility } from './transport'
import type { DeclarativeConsoleManifest, DeclarativeIconName } from './types'

const ICON_COMPONENTS: Record<DeclarativeIconName, IconComponent> = {
  board: BoardRegular,
  server: ServerRegular,
  folder: FolderRegular,
  branches: BranchRegular,
  routing: ArrowRoutingRegular,
  globe: GlobeRegular,
  people: PeopleRegular,
  doc: DocumentBulletListRegular,
  alert: AlertRegular,
  history: HistoryRegular,
  key: KeyRegular,
  scales: ScalesRegular,
  settings: SettingsRegular,
  code: CodeRegular
}

export function resolveDeclarativeIcon(name: DeclarativeIconName): IconComponent {
  return ICON_COMPONENTS[name] ?? BoardRegular
}

export function createDeclarativeConsoleModule(manifest: DeclarativeConsoleManifest): EditionWebappModule {
  const surfaceById = new Map(manifest.surfaces.map(surface => [surface.id, surface]))
  const routeById = new Map(manifest.routes.map(route => [route.id, route]))
  const routeByPath = new Map(manifest.routes.map(route => [route.path, route]))

  return defineWebappModule({
    id: manifest.id,
    console: {
      routes: manifest.routes.map(route => ({
        id: route.id,
        pluginId: manifest.pluginId,
        path: route.path,
        scope: route.scope,
        load: async () => ({
          default: function DeclarativeRouteComponent() {
            return <DeclarativeRoutedPage manifest={manifest} route={route} />
          }
        })
      })),
      navSections: manifest.navSections.map(section => ({
        id: section.id,
        pluginId: manifest.pluginId,
        label: section.labelKey,
        items: section.items.map(item => ({
          id: item.id,
          pluginId: manifest.pluginId,
          to: item.to,
          match: item.match,
          label: item.labelKey,
          icon: resolveDeclarativeIcon(item.icon),
          useVisible: () => {
            const visibility = useDeclarativeVisibility(manifest.visibilityEndpoint)
            const target = surfaceById.get(item.surfaceId)
            if (visibility.isVisible(item.surfaceId, target?.surface)) return true
            const route = routeById.get(item.id) ?? routeByPath.get(item.to)
            if (route?.tabs && route.tabs.length > 0) {
              return route.tabs.some(tab => {
                const tabTarget = surfaceById.get(tab.surfaceId)
                return Boolean(tabTarget && visibility.isVisible(tabTarget.id, tabTarget.surface))
              })
            }
            return false
          }
        }))
      }))
    }
  })
}

export {
  canBlockAdvance,
  executeStepTransition,
  redactUrlCredentials,
  selectedRowIds,
  toggleTableSelectionRow,
  WizardBlockRenderer,
  type WizardExecutionScope
} from './wizard'

export {
  isSensitiveField,
  type DeclarativeConsoleManifest,
  type DeclarativeDashboardSchema,
  type DeclarativeFieldDescriptor,
  type DeclarativeFieldType,
  type DeclarativeFilterSchema,
  type DeclarativeIconName,
  type DeclarativeNavItemSpec,
  type DeclarativeNavSectionSpec,
  type DeclarativeResultSchema,
  type DeclarativeRouteSpec,
  type DeclarativeRowActionDescriptor,
  type DeclarativeRuleSection,
  type DeclarativeStepSchema,
  type DeclarativeSurfaceDescriptor,
  type WizardBlock,
  type WizardDataTableBlock,
  type WizardExternalLinkBlock,
  type WizardFieldsBlock,
  type WizardRowFilterConfig,
  type WizardRowSelectionConfig,
  type WizardStepTransition,
  type WizardSummaryBlock
} from './types'
