/** Bound active heaps while keeping foreground headroom in a 2 GiB replica. */
export class InvocationCapacity {
  private counts = { route: 0, action: 0 }
  private heaps = { route: 0, action: 0 }

  constructor(
    private routeSlots = 24,
    private actionSlots = 6,
    private heapBudget = 1536,
    private totalSlots = 32
  ) {}

  get usedHeapMb() {
    return this.heaps.route + this.heaps.action
  }

  acquire(lane: 'route' | 'action', heapMb: number) {
    const slots = lane === 'route' ? this.routeSlots : this.actionSlots
    if (
      this.counts[lane] >= slots ||
      this.counts.route + this.counts.action >= this.totalSlots ||
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
