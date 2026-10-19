import { useEffect, useRef, useState } from 'react'
import { createRoot } from 'react-dom/client'
import { Button } from '@ankole/uikit'
import './host.css'
import { createHost, type Host } from './host'

type Build = 'revision-1' | 'revision-2' | 'broken' | 'missing'
type Slot = { name: string; location: string; build: Build }
let generation = 0
const slotFor = (build: Build, location: string): Slot => ({
  name: `applet-page-1-${build}-${location}-${++generation}`,
  location,
  build
})

function App() {
  const [host] = useState(createHost)
  const [slots, setSlots] = useState<Slot[]>([])
  const mount = (build: Build, location: string) => setSlots(current => [...current, slotFor(build, location)])
  return (
    <main className="pod-page">
      <h1 className="pod-title">Pod page</h1>
      <p className="pod-lead">The host page keeps its own layout while the applets run.</p>
      <div className="pod-row">
        <Button disabled={slots.some(slot => slot.location === 'main')} onClick={() => mount('revision-1', 'main')}>
          Mount applet
        </Button>
        <Button disabled={slots.some(slot => slot.location === 'second')} onClick={() => mount('revision-2', 'second')}>
          Mount second instance
        </Button>
        <Button disabled={slots.some(slot => slot.location === 'broken')} onClick={() => mount('broken', 'broken')}>
          Mount broken applet
        </Button>
        <Button disabled={slots.some(slot => slot.location === 'missing')} onClick={() => mount('missing', 'missing')}>
          Mount missing applet
        </Button>
        <Button
          onClick={() =>
            setSlots(current => current.map(slot => (slot.location === 'main' ? slotFor('revision-2', 'main') : slot)))
          }>
          Update main
        </Button>
      </div>
      <p className="applet-title" data-check="host-style">
        Host style probe
      </p>
      <div className="pod-applets">
        {slots.map(slot => (
          <AppletSlot
            key={slot.name}
            host={host}
            slot={slot}
            onUnmount={() => setSlots(current => current.filter(value => value.name !== slot.name))}
          />
        ))}
      </div>
    </main>
  )
}

function AppletSlot({ host, slot, onUnmount }: { host: Host; slot: Slot; onUnmount: () => void }) {
  const container = useRef<HTMLDivElement>(null)
  const [error, setError] = useState<string>()
  useEffect(() => host.mount(slot.name, `/dist/${slot.build}/applet.html`, container.current!, setError), [host, slot])
  return (
    <section className="applet-slot" data-location={slot.location} data-instance={slot.name}>
      <div className="applet-mount" ref={container} />
      {error ? <p role="alert">{error}</p> : null}
      <Button size="sm" variant="ghost" onClick={onUnmount}>
        Unmount
      </Button>
    </section>
  )
}

createRoot(document.getElementById('root')!).render(<App />)
