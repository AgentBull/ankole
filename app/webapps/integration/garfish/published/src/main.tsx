import { defineApplet } from '@ankole/applet-sdk'
import logo from './logo.svg'

export const provider = defineApplet(() => (
  <main>
    <img alt="Published logo" src={logo} />
    <div className="published-background">Published background</div>
    <p className="published-font">Published font</p>
  </main>
))
