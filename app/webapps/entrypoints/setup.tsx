import { lazy, Suspense } from 'react'
import { mountApp } from '../common/mount-spa'

const SetupApp = lazy(() => import('../setup/app').then(module => ({ default: module.SetupApp })))

mountApp(
  <Suspense fallback={null}>
    <SetupApp />
  </Suspense>
)
