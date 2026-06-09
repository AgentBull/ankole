export interface SkillContentDiagnostic {
  code: string
  message: string
  severity: 'error' | 'warning'
}

const INVISIBLE_UNICODE: Array<[RegExp, string]> = [
  [/\u200b/g, 'zero width space'],
  [/\u200c/g, 'zero width non-joiner'],
  [/\u200d/g, 'zero width joiner'],
  [/\u2060/g, 'word joiner'],
  [/\ufeff/g, 'byte order mark'],
  [/\u202a|\u202b|\u202d|\u202e|\u202c/g, 'bidirectional override/control'],
  [/\u2066|\u2067|\u2068|\u2069/g, 'bidirectional isolate/control']
]

const CRITICAL_PATTERNS: Array<[RegExp, string]> = [
  [/\bignore\s+(all\s+)?(previous|prior|above)\s+(instructions?|system\s+prompt)\b/i, 'prompt override instruction'],
  [
    /\b(disregard|override)\s+(the\s+)?(system|developer)\s+(message|prompt|instructions?)\b/i,
    'system instruction override'
  ],
  [
    /\b(reveal|print|dump|exfiltrate|leak)\b[\s\S]{0,80}\b(secret|token|api[_-]?key|password|credential|cookie)s?\b/i,
    'credential exfiltration instruction'
  ],
  [
    /\b(send|post|upload|exfiltrate)\b[\s\S]{0,80}\b(secret|token|api[_-]?key|password|credential|cookie)s?\b[\s\S]{0,120}\b(https?:\/\/|webhook|pastebin|gist)\b/i,
    'external credential exfiltration'
  ],
  [
    /\b(curl|wget|fetch)\b[\s\S]{0,120}\b(secret|token|api[_-]?key|password|credential|cookie)s?\b/i,
    'network credential exfiltration'
  ]
]

export function auditSkillAppendContent(content: string): SkillContentDiagnostic[] {
  const diagnostics: SkillContentDiagnostic[] = []
  for (const [pattern, label] of INVISIBLE_UNICODE) {
    if (pattern.test(content)) {
      diagnostics.push({
        severity: 'error',
        code: 'invisible_unicode',
        message: `AGENT_APPEND.md contains ${label}`
      })
    }
  }

  for (const [pattern, label] of CRITICAL_PATTERNS) {
    if (pattern.test(content)) {
      diagnostics.push({
        severity: 'error',
        code: 'prompt_injection',
        message: `AGENT_APPEND.md contains ${label}`
      })
    }
  }

  return diagnostics
}
