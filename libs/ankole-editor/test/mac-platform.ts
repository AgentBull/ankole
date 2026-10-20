// Headless keyboard tests use the macOS bindings on every host.
Object.defineProperty(navigator, 'platform', { value: 'MacIntel', configurable: true })
