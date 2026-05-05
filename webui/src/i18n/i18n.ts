import enUS from "@locales/en-US.toml"
import zhHansCN from "@locales/zh-Hans-CN.toml"
import i18n from "i18next"
import { initReactI18next } from "react-i18next"
import { Mf2PostProcessor, Mf2ReactPreset } from "./mf2"

const resources = {
  "en-US": { translation: enUS },
  "zh-Hans-CN": { translation: zhHansCN },
}

i18n
  .use(Mf2PostProcessor)
  .use(Mf2ReactPreset)
  .use(initReactI18next)
  .init({
    lng: activeLocale(),
    fallbackLng: "en-US",
    supportedLngs: Object.keys(resources),
    resources,
    defaultNS: "translation",
    ns: ["translation"],
    postProcess: ["mf2"],
    load: "currentOnly",
    initAsync: false,
    interpolation: { escapeValue: false },
    react: { useSuspense: false },
  })

export default i18n

function activeLocale() {
  if (typeof document === "undefined") return "en-US"

  return document.documentElement.lang || "en-US"
}
