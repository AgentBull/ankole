import { useState } from 'react'
import { createRoot } from 'react-dom/client'
import { useSearchDraft } from '../../common/use-search-draft'

function SearchDraftFixture() {
  const [query, setQuery] = useState('')
  const [submitted, setSubmitted] = useState('')
  const [scope, setScope] = useState('search')
  const [draft, setDraft] = useSearchDraft(query, setSubmitted, { scope })
  return (
    <>
      <input aria-label="Search" value={draft} onChange={event => setDraft(event.target.value)} />
      <output aria-label="Submitted">{submitted}</output>
      <button onClick={() => setQuery(submitted)}>Accept URL echo</button>
      <button onClick={() => setQuery('previous query')}>Navigate back</button>
      <button onClick={() => setScope('trash')}>Change scope</button>
    </>
  )
}

createRoot(document.getElementById('root')!).render(<SearchDraftFixture />)
