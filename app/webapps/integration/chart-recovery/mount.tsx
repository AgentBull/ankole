import { useState } from 'react'
import { createRoot } from 'react-dom/client'
import { AnkoleChart, AnkoleInfographic } from '@ankole/uikit'

function InfographicRecovery() {
  const [source, setSource] = useState('infographic missing-template\ndata\n  title Broken')
  return (
    <main>
      <label>
        Diagram source
        <textarea value={source} onChange={event => setSource(event.target.value)} />
      </label>
      <AnkoleInfographic source={source} eager />
      <AnkoleChart
        ariaLabel="Sales chart"
        eager
        spec={{ type: 'column', renderer: 'svg', data: [{ x: 'Sales', y: 12 }], xField: 'x', yField: 'y' }}
      />
    </main>
  )
}

createRoot(document.getElementById('root')!).render(<InfographicRecovery />)
