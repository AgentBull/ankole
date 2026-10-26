import { lazy } from 'react'
import { mountApp } from '../../app/webapps/common/mount'
import { AuthApp } from '../../app/webapps/auth/app'

void mountApp(
  <AuthApp
    slots={{
      emailOtpChallenge: {
        pluginId: 'fixture-challenge',
        when: 'fixture.auth-challenge',
        Component: lazy(() => import('./fixture-auth-challenge'))
      }
    }}
  />
)
