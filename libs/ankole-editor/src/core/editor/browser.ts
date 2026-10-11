const nav: any = typeof navigator != 'undefined' ? navigator : { userAgent: '', vendor: '', platform: '' }
const doc: any = typeof document != 'undefined' ? document : { documentElement: { style: {} } }

const edge = /Edge\/(\d+)/.exec(nav.userAgent)
const gecko = !edge && /gecko\/(\d+)/i.test(nav.userAgent)
const chrome = !edge && /Chrome\/(\d+)/.exec(nav.userAgent)
const webkit = 'webkitFontSmoothing' in doc.documentElement.style
const safari = !edge && /Apple Computer/.test(nav.vendor)
const ios = safari && (/Mobile\/\w+/.test(nav.userAgent) || nav.maxTouchPoints > 2)

export default {
  mac: ios || /Mac/.test(nav.platform),
  windows: /Win/.test(nav.platform),
  linux: /Linux|X11/.test(nav.platform),
  edge,
  gecko,
  gecko_version: gecko ? +(/Firefox\/(\d+)/.exec(nav.userAgent) || [0, 0])[1] : 0,
  chrome: !!chrome,
  chrome_version: chrome ? +chrome[1]! : 0,
  ios,
  android: /Android\b/.test(nav.userAgent),
  webkit,
  webkit_version: webkit ? +(/\bAppleWebKit\/(\d+)/.exec(nav.userAgent) || [0, 0])[1] : 0,
  safari,
  safari_version: safari ? +(/\bVersion\/(\d+(\.\d+)?)/.exec(nav.userAgent) || [0, 0])[1] : 0,
  blink: edge || chrome
}
