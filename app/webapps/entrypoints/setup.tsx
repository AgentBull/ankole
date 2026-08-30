import { lazy, Suspense } from 'react'
import { mountApp } from '../common/mount'

const SetupApp = lazy(() => import('../setup/app').then(module => ({ default: module.SetupApp })))

void mountApp(
  <Suspense fallback={null}>
    <SetupApp />
  </Suspense>
)
