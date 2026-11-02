package writeback

import (
	"context"
	"github.com/rclone/rclone/fs"
	"github.com/rclone/rclone/vfs/vfscommon"
	"testing"
	"time"
)

func TestDeliveryUsesReservedDispatcherSlot(t *testing.T) {
	ctx, config := fs.AddConfig(t.Context())
	config.Transfers = 4
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	opt := vfscommon.Opt
	opt.WriteBack = 0
	wb := New(ctx, &opt)
	wb.ReserveTransfer()
	started := make(chan string, 10)
	put := func(name string) PutFn {
		return func(ctx context.Context) error { started <- name; <-ctx.Done(); return ctx.Err() }
	}
	for _, name := range []string{"one", "two", "three", "background"} {
		wb.Add(0, name, 1, false, put(name))
	}
	for range 3 {
		select {
		case <-started:
		case <-time.After(time.Second):
			t.Fatal("background did not start")
		}
	}
	select {
	case name := <-started:
		t.Fatalf("reserved slot used by %s", name)
	case <-time.After(30 * time.Millisecond):
	}
	delivery := wb.Add(0, "delivery", 1, false, put("delivery"))
	wb.Prioritize(delivery)
	select {
	case name := <-started:
		if name != "delivery" {
			t.Fatal(name)
		}
	case <-time.After(time.Second):
		t.Fatal("delivery waited behind backlog")
	}
	wb.Prioritize(delivery) // An already uploading item has no heap index.
}
