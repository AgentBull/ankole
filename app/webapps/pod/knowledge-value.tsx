import { Badge } from '@ankole/uikit'
import { PageMention } from './document-mentions'
import { propertyText } from './state/knowledge-draft'

const nested = (value: unknown) => value !== null && typeof value === 'object'
const chips = (value: unknown): value is unknown[] => Array.isArray(value) && !value.some(nested)

/**
 * A display projection only: the editor retains the complete metadata value. A list of plain values reads as
 * chips, a list holding records or lists puts each item on its own line, and a record puts each field on a
 * `key: value` line.
 */
export function KnowledgeValue({ value }: { value: unknown }) {
  if (chips(value)) {
    return (
      <span className="inline-flex flex-wrap gap-1 align-middle">
        {value.map((item, index) => (
          <Badge key={index} title={propertyText(item)}>
            {propertyText(item)}
          </Badge>
        ))}
      </span>
    )
  }
  if (Array.isArray(value)) {
    return (
      <span role="list" className="grid gap-1">
        {value.map((item, index) => (
          <span role="listitem" key={index}>
            <KnowledgeValue value={item} />
          </span>
        ))}
      </span>
    )
  }
  if (nested(value)) {
    return (
      <span className="grid gap-0.5">
        {Object.entries(value as Record<string, unknown>).map(([key, item]) => (
          <span key={key}>
            <span className="text-fg-secondary">{key}: </span>
            {(key === 'page_id' || key === 'subject') && typeof item === 'string' && item ? (
              <PageMention id={item} />
            ) : nested(item) && !chips(item) ? (
              <span className="block ps-3">
                <KnowledgeValue value={item} />
              </span>
            ) : (
              <KnowledgeValue value={item} />
            )}
          </span>
        ))}
      </span>
    )
  }
  return <>{propertyText(value)}</>
}
