package vfscache

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"hash"
	"io"
	"os"
	"strings"
	"syscall"

	"github.com/rclone/rclone/fs"
	"github.com/rclone/rclone/fs/object"
	"github.com/rclone/rclone/internal/ankole"
	"github.com/zeebo/blake3"
)

func (c *Cache) AnkoleState() *ankole.State {
	if remote, ok := c.fremote.(interface{ AnkoleState() *ankole.State }); ok {
		return remote.AnkoleState()
	}
	return nil
}

// Called under item.mu, before any bytes or lengths change.
func (item *Item) ankoleBegin(size int64) error {
	state := item.c.AnkoleState()
	if state == nil {
		return nil
	}
	etag := ""
	if object, ok := item.o.(interface{ AnkoleETag() string }); ok {
		etag = object.AnkoleETag()
	}
	var baseline json.RawMessage
	if ankole.Record(item.name) && !item.info.Dirty && item.o != nil {
		if err := item._ensure(0, item.info.Size); err != nil {
			return err
		}
		data, err := os.ReadFile(item.c.toOSPath(item.name))
		if err != nil {
			return err
		}
		baseline = data
	}
	write, err := state.Begin(item.c.ctx, item.name, etag, item.info.Ankole, size)
	if err != nil {
		return err
	}
	item.info.Ankole = write
	if object, ok := item.o.(interface{ AnkoleFingerprint() string }); ok {
		state.SetFingerprint(write, object.AnkoleFingerprint(), item.o.Size())
	}
	if len(baseline) > 0 {
		state.SetBaseline(write, baseline)
	}
	return item._save()
}

func (item *Item) ankoleStore(ctx context.Context, storeFn StoreFn) (bool, error) {
	state := item.c.AnkoleState()
	if state == nil {
		return false, nil
	}
	if item.info.Ankole == nil {
		if err := item.ankoleBegin(item.info.Size); err != nil {
			return true, err
		}
	}
	write := item.info.Ankole
	snapshot := state.Snapshot(write)
	if snapshot.Done && snapshot.Failure != "" {
		return true, nil
	}
	if ankole.Noise(item.name) {
		state.Complete(write, "")
		item.info.Dirty = false
		return true, item._save()
	}
	if same, err := item.ankoleUnchanged(snapshot); err != nil {
		return true, err
	} else if same {
		state.Complete(write, "")
		item.info.Dirty = false
		return true, item._save()
	}
	// The generic copier can skip equal-sized files by timestamp. A write
	// through a POSIX handle must always send the changed bytes.
	// Finish sparse downloads against the old immutable fingerprint before
	// constructing the full upload; holes must never become remote zeroes.
	if err := item._ensure(0, item.info.Size); err != nil {
		if errors.Is(err, syscall.ESTALE) {
			return true, item.ankoleReject(write, err)
		}
		return true, err
	}
	snapshot = state.UploadSnapshot(write)
	if err := item._save(); err != nil {
		return true, err
	}
	file, err := os.Open(item.c.toOSPath(item.name))
	if err != nil {
		return true, err
	}
	var source io.Reader = file
	size := item.info.Size
	if len(snapshot.BaseRecord) > 0 {
		next, err := io.ReadAll(file)
		if err != nil {
			_ = file.Close()
			return true, err
		}
		body, err := json.Marshal(map[string]json.RawMessage{"base": snapshot.BaseRecord, "next": next})
		if err != nil {
			_ = file.Close()
			return true, item.ankoleReject(write, err)
		}
		source = bytes.NewReader(body)
		size = int64(len(body))
	}
	info := object.NewStaticObjectInfo(item.name, item.info.ModTime, size, true, nil, item.c.fremote)
	var object fs.Object
	item.mu.Unlock()
	release, err := state.Upload(ctx, write)
	if err == nil {
		object, err = item.c.fremote.Put(ankole.WithWrite(ctx, &snapshot), source, info)
		release()
	}
	_ = file.Close()
	item.mu.Lock()
	if err != nil {
		if !ankole.Terminal(err) {
			return true, err
		}
		return true, item.ankoleReject(write, err)
	}
	refresh := ankole.Record(item.name)
	if result, ok := object.(interface{ AnkoleRefreshBody() bool }); ok {
		refresh = refresh || result.AnkoleRefreshBody()
	}
	changed := state.Snapshot(write).Seq != snapshot.UploadSeq
	nodeID := ""
	if metadata, ok := object.(interface{ AnkoleNodeID() string }); ok {
		nodeID = metadata.AnkoleNodeID()
	}
	if refresh {
		state.ForgetRead(item.name)
		item.ankolePending = object
	} else {
		item.o = object
		item._updateFingerprint()
	}
	if changed {
		etag := snapshot.BaseETag
		if baseline, ok := item.o.(interface{ AnkoleETag() string }); ok {
			etag = baseline.AnkoleETag()
		}
		state.NextUpload(write, etag)
		if baseline, ok := item.o.(interface{ AnkoleFingerprint() string }); ok {
			state.SetFingerprint(write, baseline.AnkoleFingerprint(), item.o.Size())
		}
		if err := item._save(); err != nil {
			return true, err
		}
		return true, fmt.Errorf("file changed during upload: %s", item.name)
	}
	state.Complete(write, nodeID)
	// Keep this upload dirty while invalidating sibling Base projections;
	// resetting this item would wait for the upload currently executing here.
	if ankole.Tabular(item.name) && state.Invalidate != nil && nodeID != "" {
		item.mu.Unlock()
		state.Invalidate([]string{"id:" + nodeID})
		item.mu.Lock()
	}
	item.info.Dirty = false
	if refresh && item.opens == 0 {
		if err := item.ankoleApplyPending(); err != nil {
			return true, err
		}
	}
	if ankole.Sink(item.name) {
		if err := item._truncate(0); err != nil {
			return true, err
		}
		item.info.Rs = nil
	}
	if storeFn != nil && item.ankolePending == nil {
		item.mu.Unlock()
		storeFn(object)
		item.mu.Lock()
	}
	return true, item._save()
}

// Call under item.mu. A partial sparse file must first hydrate before hashing.
func (item *Item) ankoleUnchanged(write ankole.Write) (bool, error) {
	if write.UploadSeq != 0 || item.o == nil || item.info.Rs.Size() != item.info.Size || item.info.Size != write.BaseSize {
		return false, nil
	}
	algorithm, expected, ok := strings.Cut(write.BaseFingerprint, ":")
	if !ok {
		return false, nil
	}
	var digest hash.Hash
	switch algorithm {
	case "sha256":
		digest = sha256.New()
	case "blake3":
		digest = blake3.New()
	default:
		return false, nil
	}
	file, err := os.Open(item.c.toOSPath(item.name))
	if err != nil {
		return false, err
	}
	defer file.Close()
	if _, err = io.Copy(digest, file); err != nil {
		return false, err
	}
	return hex.EncodeToString(digest.Sum(nil)) == expected, nil
}

func (item *Item) ankoleApplyPending() error {
	remote := item.ankolePending
	if remote == nil {
		return nil
	}
	if previous := item.downloaders; previous != nil {
		item.downloaders = nil
		item.mu.Unlock()
		_ = previous.Close(nil)
		item.mu.Lock()
	}
	if err := item._truncate(0); err != nil {
		return err
	}
	item.info.Rs = nil
	if err := item._truncate(remote.Size()); err != nil {
		return err
	}
	item.o = remote
	item.ankolePending = nil
	item._updateFingerprint()
	return item._save()
}

func (item *Item) ankoleReject(write *ankole.Write, cause error) error {
	if err := item.c.AnkoleState().Recover(write, item.c.toOSPath(item.name), cause); err != nil {
		return err
	}
	item.info.Dirty = false
	return item._save()
}

// A rejected draft lives in recovery. Reopening starts from the current remote
// revision so fixing a document or permission does not require a Worker restart.
func (item *Item) ankoleReopen(o fs.Object) error {
	state := item.c.AnkoleState()
	if state == nil || item.opens != 0 || item.info.Ankole == nil || state.Snapshot(item.info.Ankole).Failure == "" {
		return nil
	}
	if remote, ok := o.(interface{ AnkoleRefresh(context.Context) error }); ok {
		if err := remote.AnkoleRefresh(item.c.ctx); err != nil {
			return err
		}
	}
	item.info.clean()
	return nil
}

func (item *Item) ankoleReadBaseline() {
	state := item.c.AnkoleState()
	if state == nil || !ankole.Record(item.name) || item.info.Dirty || item.info.Rs.Size() != item.info.Size {
		return
	}
	if data, err := os.ReadFile(item.c.toOSPath(item.name)); err == nil {
		state.RecordOpened(item.name, data)
	}
}

// Retry only before this open has delivered any bytes. Later sparse range
// failures remain ESTALE, so two remote revisions never share one read stream.
func (item *Item) ankoleRefreshFirstRead(offset int64, readErr error) bool {
	if offset != 0 || !errors.Is(readErr, syscall.ESTALE) || item.ankoleDelivered || item.info.Dirty || item.opens != 1 {
		return false
	}
	remote, ok := item.o.(interface{ AnkoleRefresh(context.Context) error })
	if !ok {
		return false
	}
	previous := item.downloaders
	item.downloaders = nil
	item.mu.Unlock()
	if previous != nil {
		_ = previous.Close(nil)
	}
	err := remote.AnkoleRefresh(item.c.ctx)
	item.mu.Lock()
	if err != nil {
		return false
	}
	item.info.Rs = nil
	if item._truncate(0) != nil || item._truncate(item.o.Size()) != nil {
		return false
	}
	item._updateFingerprint()
	return true
}

func (c *Cache) AnkolePrioritize(names []string) {
	selected := map[string]bool{}
	for _, name := range names {
		selected[name] = true
	}
	for _, queued := range c.writeback.Queue() {
		if selected[queued.Name] {
			c.writeback.Prioritize(queued.ID)
		}
	}
}

func (c *Cache) AnkoleInvalidate(names []string) {
	selected := map[string]bool{}
	for _, name := range names {
		selected[name] = true
	}
	c.mu.Lock()
	items := make([]*Item, 0, len(c.item))
	for name, item := range c.item {
		item.mu.Lock()
		nodeID := ""
		if object, ok := item.o.(interface{ AnkoleNodeID() string }); ok {
			nodeID = object.AnkoleNodeID()
		}
		item.mu.Unlock()
		if len(names) == 0 || selected[name] || selected["id:"+nodeID] {
			items = append(items, item)
		}
	}
	c.mu.Unlock()
	for _, item := range items {
		if !ankole.Noise(item.GetName()) && !item.IsDirty() {
			_, _, _ = item.Reset()
		}
	}
}

// Source reads stay sparse; only dirty bytes need a commit before server COPY.
func (item *Item) AnkoleCopySource(ctx context.Context, storeFn StoreFn) (fs.Object, error) {
	item.mu.Lock()
	defer item.mu.Unlock()
	if item.info.Dirty {
		if _, err := item.ankoleStore(ctx, storeFn); err != nil {
			return nil, err
		}
	}
	if item.info.Ankole != nil && item.c.AnkoleState().Snapshot(item.info.Ankole).Failure != "" {
		return nil, syscall.EIO
	}
	if item.ankolePending != nil {
		return nil, syscall.EAGAIN
	}
	return item.o, nil
}
func (item *Item) AnkoleCopyFrom(ctx context.Context, source fs.Object) (fs.Object, error) {
	item.mu.Lock()
	defer item.mu.Unlock()
	remote, ok := item.c.fremote.(interface {
		AnkoleCopy(context.Context, fs.Object, string, string, string) (fs.Object, error)
	})
	if !ok || item.info.Size != 0 {
		return nil, syscall.EOPNOTSUPP
	}
	if err := item.ankoleBegin(0); err != nil {
		return nil, err
	}
	state := item.c.AnkoleState()
	write := item.info.Ankole
	receipt := state.Snapshot(write)
	copied, err := remote.AnkoleCopy(ctx, source, item.name, receipt.RequestID, receipt.BaseETag)
	if err != nil {
		return nil, err
	}
	state.Complete(write, "")
	item.info.Dirty = false
	item.info.Ankole = nil
	item.ankolePending = copied
	if err := item.ankoleApplyPending(); err != nil {
		return nil, err
	}
	return copied, nil
}

// A rejected atomic save reports the draft through the same recovery/flush
// contract as a rejected PUT, even when its temporary file already uploaded.
func (c *Cache) AnkoleRenameFailed(ctx context.Context, name, destination string, cause error) error {
	item, _ := c.get(name)
	item.mu.Lock()
	defer item.mu.Unlock()
	if err := item._ensure(0, item.info.Size); err != nil {
		return err
	}
	state := c.AnkoleState()
	write, err := state.Begin(ctx, destination, state.ReadETag(destination), nil, item.info.Size)
	if err != nil {
		return err
	}
	item.info.Ankole = write
	return item.ankoleReject(write, cause)
}
