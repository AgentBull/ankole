export type InvocationLane = 'route' | 'action' | 'ptc'

/** Bound active heaps while keeping foreground Applet concurrency headroom in a 2 GiB replica. */
export class InvocationCapacity {
  private counts = { route: 0, action: 0, ptc: 0 }
  private heaps = { route: 0, action: 0, ptc: 0 }

  constructor(
    private routeSlots = 32,
    private actionSlots = 6,
    private heapBudget = 1536,
    private totalSlots = 32
  ) {}

  get usedHeapMb() {
    return this.heaps.route + this.heaps.action + this.heaps.ptc
  }

  acquire(lane: InvocationLane, heapMb: number) {
    const totalActive = this.counts.route + this.counts.action + this.counts.ptc
    const ptcSlots = Math.max(1, Math.min(this.routeSlots, this.totalSlots) - 2)
    const slots = lane === 'route' ? this.routeSlots : lane === 'action' ? this.actionSlots : ptcSlots
    const totalLimit = lane === 'ptc' ? ptcSlots : this.totalSlots
    if (
      this.counts[lane] >= slots ||
      totalActive >= totalLimit ||
      this.usedHeapMb + heapMb > this.heapBudget ||
      (lane === 'action' && this.heaps.action + heapMb > this.heapBudget - 384)
    ) {
      return null
    }
    this.counts[lane]++
    this.heaps[lane] += heapMb
    let released = false
    return () => {
      if (released) return
      released = true
      this.counts[lane]--
      this.heaps[lane] -= heapMb
    }
  }
}
