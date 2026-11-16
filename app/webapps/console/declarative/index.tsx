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
            return visibility.isVisible(item.surfaceId, target?.surface)
          }
        }))
      }))
    }
  })
}

export type {
  DeclarativeConsoleManifest,
  DeclarativeDashboardSchema,
  DeclarativeFieldDescriptor,
  DeclarativeFilterSchema,
  DeclarativeIconName,
  DeclarativeNavItemSpec,
  DeclarativeNavSectionSpec,
  DeclarativeResultSchema,
  DeclarativeRouteSpec,
  DeclarativeRowActionDescriptor,
  DeclarativeRuleSection,
  DeclarativeStepSchema,
  DeclarativeSurfaceDescriptor
} from './types'
