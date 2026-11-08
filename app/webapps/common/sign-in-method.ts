import { localizedText } from './config-fields'
import { humanizeTechnicalLabel } from './humanize-technical-label'

/** Names how an identity signed in, using the platform name the control plane resolved for its provider. */
export function signInMethodLabel(
  identity: { providerID: string; providerName?: unknown },
  locale: string,
  emailLabel: string
): string {
  if (identity.providerID === 'email_otp') return emailLabel
  return localizedText(identity.providerName, locale) ?? humanizeTechnicalLabel(identity.providerID)
}
