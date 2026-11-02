package vfscache

import (
	"context"
	"testing"
	"time"
)

func TestAnkoleQuotaStopsOnCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(t.Context())
	t.Cleanup(cancel)
	done := make(chan struct{})
	go func() {
		ankoleRunQuota(ctx)
		close(done)
	}()
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("cache quota worker did not stop after cancellation")
	}
}

func TestProviderCapacityUsesKubernetesQuantityUnits(t *testing.T) {
	for raw, want := range map[string]int64{"5Gi": 5 << 30, "128Mi": 128 << 20, "5G": 5000000000, "1000": 1000, "1.5Gi": 3 << 29, "1e9": 1000000000, "100m": 1, "": 0} {
		if got := ankoleCapacity(raw); got != want {
			t.Fatalf("%s: got %d, want %d", raw, got, want)
		}
	}
}
