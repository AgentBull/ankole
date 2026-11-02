package writeback

import "time"

// Keep one local dispatcher slot free so a delivery can reach the global
// transfer limiter even when this mount has a large background queue.
func (wb *WriteBack) ReserveTransfer() {
	wb.mu.Lock()
	wb.ankole = true
	wb.mu.Unlock()
}
func (wb *WriteBack) Prioritize(id Handle) {
	wb.mu.Lock()
	defer wb.mu.Unlock()
	item := wb.lookup[id]
	if item == nil || item.uploading {
		return
	}
	item.priority = true
	wb.items._update(item, time.Unix(0, 0))
	wb._resetTimer()
}
