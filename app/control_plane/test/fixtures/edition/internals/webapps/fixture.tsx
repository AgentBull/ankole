import { lazy } from 'react'
import { mountApp } from '../../app/webapps/common/mount'
import { PodApp } from '../../app/webapps/pod/app'
void mountApp(
  <PodApp
    slots={{
      settingsTabs: [
        {
          id: 'fixture-module',
          pluginId: 'fixture-pod-settings',
          labelKey: 'edition_fixture.message',
          when: 'fixture.pod-module',
          Component: lazy(() => import('./fixture-pod-module'))
        }
      ],
      accountNavigation: {
        pluginId: 'fixture-pod-settings',
        content: <span className="text-[123.456px]">SaaS build fixture</span>
      }
    }}
  />
)
