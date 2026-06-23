import i18n from 'i18next'
import { initReactI18next } from 'react-i18next'

const resources = {
  'en-US': {
    translation: {
      auth: {
        description: 'Sign in with the identity provider configured during setup.',
        no_providers: 'No identity providers are configured.',
        provider_label: 'Identity provider',
        sign_in: 'Sign in',
        title: 'Sign in to Ankole'
      },
      common: {
        back: 'Back',
        cancel: 'Cancel',
        continue: 'Continue',
        error: 'Request failed',
        loading: 'Loading',
        placeholder: 'Placeholder',
        ready: 'Ready for implementation',
        save: 'Save'
      },
      console: {
        description:
          'The authenticated console shell is mounted with routing, query state, i18n, and document head support.',
        title: 'Ankole Console'
      },
      setup: {
        activation_code: 'Bootstrap activation code',
        activation_hint: 'Use the activation code printed in the server log for this process.',
        adapter: 'Identity provider adapter',
        adapter_config: 'Adapter configuration',
        authenticated_note: 'Setup session active',
        bootstrap_title: 'Unlock setup',
        choose_plugins: 'Choose plugins',
        complete_with_oidc: 'Save and sign in with OIDC',
        description:
          'Choose installation plugins, configure the first identity provider, and claim the first administrator.',
        identity_provider: 'Identity provider',
        language: 'Language',
        no_adapters: 'No enabled plugin exposes an identity provider adapter.',
        plugin_restart_note: 'Plugin enablement is persisted and takes full effect on the next server start.',
        provider_id: 'Provider ID',
        provider_id_hint: 'This becomes the external identity namespace stored in Principals.',
        save_plugins: 'Save plugin selection',
        step_identity: 'Identity',
        step_plugins: 'Plugins',
        title: 'Ankole setup'
      }
    }
  },
  'zh-Hans-CN': {
    translation: {
      auth: {
        description: '使用初始化期间配置的身份提供方登录。',
        no_providers: '尚未配置身份提供方。',
        provider_label: '身份提供方',
        sign_in: '登录',
        title: '登录 Ankole'
      },
      common: {
        back: '返回',
        cancel: '取消',
        continue: '继续',
        error: '请求失败',
        loading: '加载中',
        placeholder: '占位',
        ready: '已就绪',
        save: '保存'
      },
      console: {
        description: '控制台 shell 已挂载，后续功能会在这里展开。',
        title: 'Ankole 控制台'
      },
      setup: {
        activation_code: '启动激活码',
        activation_hint: '使用当前服务进程日志里打印的激活码。',
        adapter: '身份提供方适配器',
        adapter_config: '适配器配置',
        authenticated_note: 'Setup 会话已开启',
        bootstrap_title: '开启初始化',
        choose_plugins: '选择插件',
        complete_with_oidc: '保存并使用 OIDC 登录',
        description: '选择安装插件，配置第一个身份提供方，并认领第一个管理员。',
        identity_provider: '身份提供方',
        language: '语言',
        no_adapters: '当前启用的插件没有提供身份提供方适配器。',
        plugin_restart_note: '插件启用状态已保存，完整生效需要下次服务启动。',
        provider_id: 'Provider ID',
        provider_id_hint: '它会成为 Principals 中的外部身份命名空间。',
        save_plugins: '保存插件选择',
        step_identity: '身份',
        step_plugins: '插件',
        title: 'Ankole 初始化'
      }
    }
  }
}

i18n.use(initReactI18next).init({
  fallbackLng: 'en-US',
  initAsync: false,
  interpolation: { escapeValue: false },
  // The Phoenix shell writes the server-selected locale to `<html lang>`, so
  // the SPA starts with the same locale before it fetches any user state.
  lng: document.documentElement.lang || 'en-US',
  resources,
  supportedLngs: ['en-US', 'zh-Hans-CN']
})

export default i18n

/** Returns a short native-language label for locale pickers. */
export function nativeLocaleLabel(locale: string): string {
  const labels: Record<string, string> = {
    'en-US': 'English',
    'zh-Hans-CN': '简体中文'
  }

  return labels[locale] ?? locale
}
