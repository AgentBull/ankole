import { useTranslation } from 'react-i18next'
import { SubNav } from '../../console-list-page'

/** Absolute route to one object's drawer; slugs encode per segment so `/` survives. */
export function brainObjectPath(slug: string): string {
  return `/brain/objects/${slug.split('/').map(encodeURIComponent).join('/')}`
}

export function brainObjectEditPath(slug: string): string {
  return `/brain/objects/${encodeURIComponent(slug)}/edit`
}

/** Tab strip shared by every Brain page; the side nav lists the area once. */
export function BrainSubNav() {
  const { t } = useTranslation()

  return (
    <SubNav
      ariaLabel={t('console.brain.sections')}
      items={[
        { to: '/brain/objects', label: t('console.brain.objects') },
        { to: '/brain/claims', label: t('console.brain.claims') },
        { to: '/brain/contradictions', label: t('console.brain.contradictions') },
        { to: '/brain/suggestions', label: t('console.brain.suggestions') },
        { to: '/brain/merge-suggestions', label: t('console.brain.merge_suggestions') },
        { to: '/brain/sources', label: t('console.brain.sources') },
        { to: '/brain/search-preview', label: t('console.brain.search_preview') },
        { to: '/brain/principal-audit', label: t('console.brain.principal_audit') },
        { to: '/brain/health', label: t('console.brain.health') }
      ]}
    />
  )
}
