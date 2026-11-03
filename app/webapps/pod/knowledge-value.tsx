import { PageMention } from './document-mentions'
import { propertyText } from './state/knowledge-draft'

/** A display projection only: the editor retains the complete metadata value. */
export function KnowledgeValue({ value }: { value: unknown }) {
  if (Array.isArray(value)) {
    return (
      <>
        {'['}
        {value.map((item, index) => (
          <span key={index}>
            {index > 0 && ', '}
            <KnowledgeValue value={item} />
          </span>
        ))}
        {']'}
      </>
    )
  }
  if (value !== null && typeof value === 'object') {
    return (
      <>
        {'{'}
        {Object.entries(value).map(([key, item], index) => (
          <span key={key}>
            {index > 0 && ', '}
            {key}:{' '}
            {(key === 'page_id' || key === 'subject') && typeof item === 'string' && item ? (
              <PageMention id={item} />
            ) : (
              <KnowledgeValue value={item} />
            )}
          </span>
        ))}
        {'}'}
      </>
    )
  }
  return <>{propertyText(value)}</>
}
