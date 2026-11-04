import type { CronEditorLabels } from '@ankole/uikit'
import type { TFunction } from 'i18next'

export function cronEditorLabels(t: TFunction): CronEditorLabels {
  return {
    mode: t('common.cron_mode'),
    modes: {
      every_minutes: t('common.cron_mode_every_minutes'),
      hourly: t('common.cron_mode_hourly'),
      daily: t('common.cron_mode_daily'),
      weekly: t('common.cron_mode_weekly'),
      monthly: t('common.cron_mode_monthly'),
      custom: t('common.cron_mode_custom')
    },
    interval: t('common.cron_interval'),
    minute: t('common.cron_minute'),
    time: t('common.cron_time'),
    weekday: t('common.cron_weekday'),
    weekdays: [
      t('common.cron_weekday_sun'),
      t('common.cron_weekday_mon'),
      t('common.cron_weekday_tue'),
      t('common.cron_weekday_wed'),
      t('common.cron_weekday_thu'),
      t('common.cron_weekday_fri'),
      t('common.cron_weekday_sat')
    ],
    dayOfMonth: t('common.cron_day_of_month'),
    expression: t('common.cron_expression')
  }
}
