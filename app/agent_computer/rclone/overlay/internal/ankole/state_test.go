package ankole

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"

	"github.com/rclone/rclone/fs/rc"
)

type testRemote struct{}

func (testRemote) SetToken(string) {}
func testState(t *testing.T) *State {
	t.Helper()
	state := New(t.Name(), testRemote{})
	t.Cleanup(func() { states.Delete(t.Name()); dirtyBytes.Store(0) })
	return state
}

func TestSnapshotOwnsItsRecordBaseline(t *testing.T) {
	s := testState(t)
	w, err := s.Begin(t.Context(), "table._abase/rec_x.json", "", nil, 1)
	if err != nil {
		t.Fatal(err)
	}
	s.SetBaseline(w, []byte(`{"Name":"old"}`))
	snapshot := s.Snapshot(w)
	snapshot.BaseRecord[0] = '['
	if got := string(s.Snapshot(w).BaseRecord); got != `{"Name":"old"}` {
		t.Fatalf("snapshot mutation changed the upload baseline: %s", got)
	}
}

func TestCanceledWorkDoesNotAcquireCapacity(t *testing.T) {
	s := testState(t)
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	if _, err := s.Begin(ctx, "canceled.txt", "", nil, 1); !errors.Is(err, context.Canceled) {
		t.Fatalf("canceled write: %v", err)
	}
	if dirtyBytes.Load() != 0 || len(s.writes) != 0 {
		t.Fatal("canceled write acquired dirty capacity")
	}
	w, err := s.Begin(t.Context(), "upload.txt", "", nil, 1)
	if err != nil {
		t.Fatal(err)
	}
	if release, err := s.Upload(ctx, w); !errors.Is(err, context.Canceled) {
		if release != nil {
			release()
		}
		t.Fatalf("canceled upload: %v", err)
	}
}

func TestInvalidRecoveryMetadataKeepsLocalFile(t *testing.T) {
	s := testState(t)
	s.Recovery = filepath.Join(t.TempDir(), "recovery")
	local := filepath.Join(t.TempDir(), "draft.json")
	if err := os.WriteFile(local, []byte("unfinished draft"), 0600); err != nil {
		t.Fatal(err)
	}
	w, err := s.Begin(t.Context(), "table._abase/rec_x.json", "", nil, 1)
	if err != nil {
		t.Fatal(err)
	}
	s.SetBaseline(w, []byte("invalid json"))
	if err := s.Recover(w, local, syscall.ESTALE); err == nil {
		t.Fatal("invalid recovery metadata was silently discarded")
	}
	if contents, err := os.ReadFile(local); err != nil || string(contents) != "unfinished draft" {
		t.Fatalf("recovery failure lost the draft: %q, %v", contents, err)
	}
}

func TestOpenWorkingSetFailsInsteadOfWaitingForItsOwnClose(t *testing.T) {
	s := testState(t)
	var first *Write
	for i := range 10 {
		w, err := s.Begin(t.Context(), fmt.Sprint(i), "", nil, 100<<20)
		if err != nil {
			t.Fatal(err)
		}
		if i == 0 {
			first = w
		}
	}
	if _, err := s.Begin(t.Context(), "overflow", "", nil, 25<<20); !errors.Is(err, syscall.ENOSPC) {
		t.Fatalf("got %v", err)
	}
	if _, err := s.Begin(t.Context(), "oversize", "", nil, 101<<20); !errors.Is(err, syscall.EFBIG) {
		t.Fatalf("got %v", err)
	}
	s.Complete(first, "id")
	if _, err := s.Begin(t.Context(), "room", "", nil, 25<<20); err != nil {
		t.Fatal(err)
	}
}

func TestClosedUploadReleasesBackpressureAndLargeWindowsStayBackground(t *testing.T) {
	s := testState(t)
	dirtyBytes.Store(512 << 20)
	w, _ := s.Begin(t.Context(), "drain", "", nil, 0)
	s.Closed(w)
	done := make(chan error, 1)
	go func() { _, err := s.Begin(t.Context(), "next", "", nil, 1); done <- err }()
	select {
	case err := <-done:
		t.Fatalf("write did not wait: %v", err)
	case <-time.After(60 * time.Millisecond):
	}
	s.Complete(w, "id")
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("write remained blocked")
	}
	dirtyBytes.Store(0)
	for i := range 20000 {
		if _, err := s.Begin(t.Context(), fmt.Sprint(i), "", nil, 0); err != nil {
			t.Fatal(err)
		}
	}
	result, err := s.control(t.Context(), "flush", rc.Params{"since_seq": 0})
	if err != nil || result["background"] != true {
		t.Fatalf("%v %v", result, err)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, w := range s.writes {
		if w.Priority {
			t.Fatal("background batch consumed delivery priority")
		}
	}
}

func TestDeliveryHasCapacityWhileThreeBackgroundTransfersWait(t *testing.T) {
	s := testState(t)
	var releases []func()
	for i := range 3 {
		w, _ := s.Begin(t.Context(), fmt.Sprint(i), "", nil, 0)
		release, err := s.Upload(t.Context(), w)
		if err != nil {
			t.Fatal(err)
		}
		releases = append(releases, release)
	}
	defer func() {
		for _, release := range releases {
			release()
		}
	}()
	w, _ := s.Begin(t.Context(), "delivery", "", nil, 0)
	w.Priority = true
	ctx, cancel := context.WithTimeout(t.Context(), time.Second)
	defer cancel()
	release, err := s.Upload(ctx, w)
	if err != nil {
		t.Fatal(err)
	}
	release()
}

func TestReceiptPersistsAndSuccessfulQueueEntriesAreRetired(t *testing.T) {
	s := testState(t)
	w, _ := s.Begin(t.Context(), "record._abase/rec_x.json", "", nil, 10)
	s.SetBaseline(w, []byte(`{"Name":"old","_versions":{"Name":1}}`))
	raw, err := json.Marshal(w)
	if err != nil {
		t.Fatal(err)
	}
	var restored Write
	if err = json.Unmarshal(raw, &restored); err != nil {
		t.Fatal(err)
	}
	if restored.RequestID != w.RequestID || restored.RequestMillis != w.RequestMillis || len(restored.BaseRecord) == 0 {
		t.Fatal("lost retry identity")
	}
	s.Complete(w, "node")
	if len(s.writes) != 0 || dirtyBytes.Load() != 0 {
		t.Fatal("successful upload retained quota or queue entry")
	}
}

func TestSmallCacheVolumeBoundsOpenDirtyHandles(t *testing.T) {
	s := testState(t)
	SetDiskCapacity(128 << 20)
	defer func() { diskDirtyLimit.Store(0); diskFileLimit.Store(0) }()
	if _, err := s.Begin(t.Context(), "oversize", "", nil, 45<<20); !errors.Is(err, syscall.EFBIG) {
		t.Fatalf("file exceeded half the cache quota: %v", err)
	}
	for _, name := range []string{"first", "second"} {
		if _, err := s.Begin(t.Context(), name, "", nil, 40<<20); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := s.Begin(t.Context(), "overflow", "", nil, 10<<20); !errors.Is(err, syscall.ENOSPC) {
		t.Fatalf("small cache admitted an undrainable working set: %v", err)
	}
}

func TestRenameEntersTheCurrentFlushWindow(t *testing.T) {
	s := testState(t)
	w, err := s.Begin(t.Context(), "temporary", "", nil, 1)
	if err != nil {
		t.Fatal(err)
	}
	before := s.seq
	s.Rename(w, "report.txt")
	if w.Seq <= before || s.writes["report.txt"] != w {
		t.Fatal("rename stayed in the previous write window")
	}
}

func TestCompletedRenameDoesNotReturnTheConsumedSourceAsAnAttachment(t *testing.T) {
	s := testState(t)
	w, err := s.Begin(t.Context(), "temporary", "", nil, 10)
	if err != nil {
		t.Fatal(err)
	}
	s.Complete(w, "source-node")
	s.Rename(w, "report.txt")
	result, err := s.control(t.Context(), "flush-paths", rc.Params{"paths": []string{"report.txt"}})
	if err != nil {
		t.Fatal(err)
	}
	if len(result["files"].([]Write)) != 0 {
		t.Fatalf("completed rename returned the consumed source: %v", result)
	}
}
