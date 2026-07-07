type JobQueueOptions<TJob> = {
  maxRunning: number
  getGroupId: (job: TJob) => string
  getJobId: (job: TJob) => string
  run: (job: TJob) => Promise<void>
  onError?: (job: TJob, error: unknown) => void
}

export class JobQueue<TJob> {
  private queuedByGroup = new Map<string, TJob[]>()
  private runningByGroup = new Map<string, Set<string>>()

  constructor(private readonly options: JobQueueOptions<TJob>) {}

  enqueue(job: TJob): void {
    const groupId = this.options.getGroupId(job)
    const queue = this.queuedByGroup.get(groupId) ?? []
    queue.push(job)
    this.queuedByGroup.set(groupId, queue)
    this.pump(groupId)
  }

  remove(job: TJob): void {
    const groupId = this.options.getGroupId(job)
    const jobId = this.options.getJobId(job)
    const queue = this.queuedByGroup.get(groupId) ?? []
    this.queuedByGroup.set(
      groupId,
      queue.filter(item => this.options.getJobId(item) !== jobId)
    )
  }

  requeueLater(job: TJob, delayMs: number, shouldRequeue: () => boolean): void {
    setTimeout(() => {
      if (!shouldRequeue()) return
      this.enqueue(job)
    }, delayMs)
  }

  private pump(groupId: string): void {
    const running = this.runningByGroup.get(groupId) ?? new Set<string>()
    const queue = this.queuedByGroup.get(groupId) ?? []

    while (running.size < this.options.maxRunning && queue.length > 0) {
      const job = queue.shift()!
      const jobId = this.options.getJobId(job)
      running.add(jobId)
      this.runningByGroup.set(groupId, running)
      void this.options
        .run(job)
        .catch(error => {
          this.options.onError?.(job, error)
        })
        .finally(() => {
          running.delete(jobId)
          this.pump(groupId)
        })
    }
  }
}
