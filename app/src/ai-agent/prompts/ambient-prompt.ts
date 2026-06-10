export const AMBIENT_RECOGNIZER_SYSTEM_PROMPT =
  'Decide whether the AI coworker should proactively intervene in this room. Return only a strict JSON object, with no markdown.'

export function buildAmbientRecognizerUserPrompt(recentMessages: string): string {
  return `Recent ambient room messages:\n${recentMessages}\n\nReturn {"intervene": boolean, "reason_summary": string}.`
}
