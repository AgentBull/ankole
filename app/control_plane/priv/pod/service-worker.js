// The Pod service worker shows Web Push notifications and opens their room when the Human clicks one.
self.addEventListener('install', () => self.skipWaiting())
self.addEventListener('activate', event => event.waitUntil(self.clients.claim()))

self.addEventListener('push', event => {
  let data = {}
  try {
    data = event.data ? event.data.json() : {}
  } catch {
    data = {}
  }
  event.waitUntil(
    self.registration.showNotification(data.title || 'Ankole', {
      body: data.body || '',
      tag: data.tag,
      icon: '/images/pwa-192.png',
      data: { url: data.url || '/' },
      requireInteraction: data.decision === true
    })
  )
})

self.addEventListener('notificationclick', event => {
  event.notification.close()
  const path = (event.notification.data && event.notification.data.url) || '/'
  event.waitUntil(
    (async () => {
      const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true })
      // A sign-in page cannot open the room, so the click looks for a Pod tab past it.
      const open = windows.find(client => {
        const url = new URL(client.url)
        return url.origin === self.location.origin && !url.pathname.startsWith('/sessions')
      })
      if (open) {
        await open.focus()
        open.postMessage({ type: 'ankole:open', url: path })
        return
      }
      await self.clients.openWindow(new URL(path, self.location.origin).href)
    })()
  )
})
