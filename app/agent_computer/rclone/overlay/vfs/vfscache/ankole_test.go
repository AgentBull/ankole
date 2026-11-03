package vfscache

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"

	"github.com/rclone/rclone/fs"
	"github.com/rclone/rclone/fs/rc"
	"github.com/rclone/rclone/fstest"
	"github.com/rclone/rclone/internal/ankole"
	"github.com/rclone/rclone/vfs/vfscommon"
	"github.com/stretchr/testify/require"
)

type refreshObject struct {
	fs.Object
	etag    string
	refresh bool
}

func (o refreshObject) AnkoleETag() string      { return o.etag }
func (o refreshObject) AnkoleRefreshBody() bool { return o.refresh }
func (o refreshObject) AnkoleNodeID() string    { return "node" }

// Model the control plane's receipt: replay acknowledges the original bytes,
// even if a client mistakenly retries that request ID with a different body.
type receiptRemote struct {
	fs.Fs
	state       *ankole.State
	requestID   string
	response    fs.Object
	afterCommit func() error
}

func (f *receiptRemote) SetToken(string)            {}
func (f *receiptRemote) AnkoleState() *ankole.State { return f.state }
func (f *receiptRemote) Put(ctx context.Context, input io.Reader, source fs.ObjectInfo, opts ...fs.OpenOption) (fs.Object, error) {
	headers := ankole.Headers(ctx)
	id := headers["X-Ankole-Request-Id"]
	if id == f.requestID {
		return f.response, nil
	}
	if f.response != nil && headers["If-Match"] != f.requestID {
		return nil, &ankole.TerminalError{Status: 412, Message: "incorrect upload baseline"}
	}
	o, err := f.Fs.Put(ctx, input, source, opts...)
	if err != nil {
		return nil, err
	}
	f.requestID = id
	f.response = refreshObject{o, id, false}
	if f.afterCommit != nil {
		if err := f.afterCommit(); err != nil {
			return nil, err
		}
	}
	return f.response, nil
}

func newReceiptCache(t *testing.T) (*Item, *receiptRemote) {
	t.Helper()
	r := fstest.NewRun(t)
	remote := &receiptRemote{Fs: r.Fremote}
	remote.state = ankole.New(t.Name(), remote)
	opt := vfscommon.Opt
	opt.CachePollInterval = 0
	opt.HandleCaching = 0
	opt.WriteBack = 0
	ctx, cancel := context.WithCancel(t.Context())
	c, err := New(ctx, remote, &opt, nil)
	require.NoError(t, err)
	t.Cleanup(func() { cancel(); ankoleCaches.Delete(c.root); require.NoError(t, c.CleanUp()) })
	item := c.Item("draft")
	require.NoError(t, item.Open(nil))
	return item, remote
}

func TestAnkoleLostUploadReplyDoesNotDiscardLaterEdits(t *testing.T) {
	item, remote := newReceiptCache(t)
	remote.afterCommit = func() error { return context.Canceled }
	_, err := item.WriteAt([]byte("first"), 0)
	require.NoError(t, err)
	require.ErrorIs(t, item.store(t.Context(), nil), context.Canceled)
	_, err = item.WriteAt([]byte("later"), 0)
	require.NoError(t, err)
	remote.afterCommit = nil
	// Settle the uncertain first commit, then let close finish any pending edit.
	require.ErrorContains(t, item.store(t.Context(), nil), "file changed during upload")
	require.NoError(t, item.Close(nil))
	o, err := remote.NewObject(t.Context(), "draft")
	require.NoError(t, err)
	reader, err := o.Open(t.Context())
	require.NoError(t, err)
	defer reader.Close()
	data, err := io.ReadAll(reader)
	require.NoError(t, err)
	require.Equal(t, "later", string(data))
}

func TestAnkoleFlushWaitsForEditsMadeDuringUpload(t *testing.T) {
	item, remote := newReceiptCache(t)
	committed, respond := make(chan struct{}), make(chan struct{})
	remote.afterCommit = func() error {
		close(committed)
		<-respond
		return nil
	}
	_, err := item.WriteAt([]byte("first"), 0)
	require.NoError(t, err)
	stored := make(chan error, 1)
	go func() { stored <- item.store(t.Context(), nil) }()
	<-committed
	_, err = item.WriteAt([]byte("later"), 0)
	require.NoError(t, err)
	selected := make(chan struct{})
	remote.state.Prioritize = func([]string) { close(selected) }
	flushed := make(chan error, 1)
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	go func() {
		_, err := rc.Calls.Get("ankole/flush-paths").Fn(ctx, rc.Params{"fs": t.Name(), "paths": []string{"draft"}})
		flushed <- err
	}()
	<-selected
	close(respond)
	require.Error(t, <-stored)
	select {
	case err := <-flushed:
		t.Fatalf("flush returned before the later edit uploaded: %v", err)
	case <-time.After(60 * time.Millisecond):
	}
	remote.afterCommit = nil
	require.NoError(t, item.Close(nil))
	require.NoError(t, <-flushed)
}

type refreshRemote struct {
	fs.Fs
	state     *ankole.State
	response  fs.Object
	baselines []string
}

func (f *refreshRemote) SetToken(string)            {}
func (f *refreshRemote) AnkoleState() *ankole.State { return f.state }
func (f *refreshRemote) Put(ctx context.Context, input io.Reader, source fs.ObjectInfo, opts ...fs.OpenOption) (fs.Object, error) {
	f.baselines = append(f.baselines, ankole.Headers(ctx)["If-Match"])
	if _, err := io.Copy(io.Discard, input); err != nil {
		return nil, err
	}
	if len(f.baselines) > 1 {
		return nil, &ankole.TerminalError{Status: 412, Message: "newer browser version"}
	}
	return f.response, nil
}

func newRefreshCache(t *testing.T) (*fstest.Run, *Cache, *refreshRemote) {
	t.Helper()
	r := fstest.NewRun(t)
	remote := &refreshRemote{Fs: r.Fremote}
	remote.state = ankole.New(t.Name(), remote)
	remote.state.Recovery = t.TempDir()
	opt := vfscommon.Opt
	opt.CachePollInterval = 0
	opt.HandleCaching = 0
	opt.WriteBack = 0
	ctx, cancel := context.WithCancel(t.Context())
	c, err := New(ctx, remote, &opt, nil)
	require.NoError(t, err)
	t.Cleanup(func() { cancel(); ankoleCaches.Delete(c.root); require.NoError(t, c.CleanUp()) })
	return r, c, remote
}

func TestAnkoleRefreshKeepsOpenHandleBaselineAndRecoversFurtherEdits(t *testing.T) {
	for _, continued := range []bool{false, true} {
		t.Run(map[bool]string{false: "clean close refreshes", true: "old handle cannot overwrite"}[continued], func(t *testing.T) {
			if continued && os.Geteuid() != 0 {
				t.Skip("recovery ownership requires the root Linux Worker; run this case in Docker")
			}
			r, c, remote := newRefreshCache(t)
			ctx := t.Context()
			r.WriteObject(ctx, "draft", "initial", time.Now())
			old, err := r.Fremote.NewObject(ctx, "draft")
			require.NoError(t, err)
			r.WriteObject(ctx, "authoritative", "browser version B", time.Now())
			latest, err := r.Fremote.NewObject(ctx, "authoritative")
			require.NoError(t, err)
			remote.response = refreshObject{latest, "B", true}
			item := c.Item("draft")
			require.NoError(t, item.Open(refreshObject{old, "old", false}))
			_, err = item.WriteAt([]byte("local A"), 0)
			require.NoError(t, err)
			require.NoError(t, item.store(ctx, nil))
			require.Equal(t, "old", item.o.(refreshObject).etag)
			require.NotNil(t, item.ankolePending)
			require.Equal(t, int64(7), item.info.Size)
			if continued {
				_, err = item.WriteAt([]byte(" plus C"), 7)
				require.NoError(t, err)
				require.NoError(t, item.store(ctx, nil))
				require.Equal(t, []string{"old", "old"}, remote.baselines)
				write := remote.state.Snapshot(item.info.Ankole)
				require.NotEmpty(t, write.Failure)
				data, err := os.ReadFile(filepath.Join(remote.state.Recovery, filepath.Base(write.Recovery)))
				require.NoError(t, err)
				require.Equal(t, "local A plus C", string(data))
			}
			require.NoError(t, item.Close(nil))
			require.Nil(t, item.ankolePending)
			require.Equal(t, "B", item.o.(refreshObject).etag)
			require.Equal(t, int64(17), item.info.Size)
			require.Zero(t, item.info.Rs.Size())
			require.NoError(t, item.Open(remote.response))
			data := make([]byte, 17)
			_, err = item.ReadAt(data, 0)
			require.NoError(t, err)
			require.Equal(t, "browser version B", string(data))
			require.NoError(t, item.Close(nil))
		})
	}
}

func TestAnkoleRefreshResetsClosedSparseCacheBeforeNextRead(t *testing.T) {
	r, c, remote := newRefreshCache(t)
	ctx := t.Context()
	r.WriteObject(ctx, "draft", "initial", time.Now())
	old, err := r.Fremote.NewObject(ctx, "draft")
	require.NoError(t, err)
	r.WriteObject(ctx, "authoritative", "merged bytes", time.Now())
	latest, err := r.Fremote.NewObject(ctx, "authoritative")
	require.NoError(t, err)
	remote.response = refreshObject{latest, "B", true}
	item := c.Item("draft")
	require.NoError(t, item.Open(refreshObject{old, "old", false}))
	_, err = item.WriteAt([]byte("local A"), 0)
	require.NoError(t, err)
	require.NoError(t, item.Close(nil))
	require.False(t, item.info.Dirty)
	require.Nil(t, item.ankolePending)
	require.Equal(t, int64(12), item.info.Size)
	require.Zero(t, item.info.Rs.Size())
	require.Equal(t, "B", item.o.(refreshObject).etag)
}

func TestAnkoleCopyRejectsSourceWhoseFlushFailed(t *testing.T) {
	if os.Geteuid() != 0 {
		t.Skip("recovery ownership requires the root Linux Worker; run this case in Docker")
	}
	r, c, remote := newRefreshCache(t)
	ctx := t.Context()
	r.WriteObject(ctx, "draft", "initial", time.Now())
	old, err := r.Fremote.NewObject(ctx, "draft")
	require.NoError(t, err)
	remote.baselines = []string{"prior commit"}
	item := c.Item("draft")
	require.NoError(t, item.Open(refreshObject{old, "old", false}))
	_, err = item.WriteAt([]byte("local A"), 0)
	require.NoError(t, err)
	copied, err := item.AnkoleCopySource(ctx, nil)
	require.ErrorIs(t, err, syscall.EIO)
	require.Nil(t, copied)
	write := remote.state.Snapshot(item.info.Ankole)
	data, err := os.ReadFile(filepath.Join(remote.state.Recovery, filepath.Base(write.Recovery)))
	require.NoError(t, err)
	require.Equal(t, "local A", string(data))
	require.NoError(t, item.Close(nil))
}

func TestAnkoleMoveRefreshResetsClosedCacheAndDefersOpenHandles(t *testing.T) {
	for _, open := range []bool{false, true} {
		t.Run(map[bool]string{false: "closed", true: "open"}[open], func(t *testing.T) {
			r, c, remote := newRefreshCache(t)
			ctx := t.Context()
			r.WriteObject(ctx, "draft", "local A", time.Now())
			old, err := r.Fremote.NewObject(ctx, "draft")
			require.NoError(t, err)
			r.WriteObject(ctx, "authoritative", "merged browser and worker", time.Now())
			merged, err := r.Fremote.NewObject(ctx, "authoritative")
			require.NoError(t, err)
			remote.response = refreshObject{merged, "merged", true}
			item := c.Item("draft")
			require.NoError(t, item.Open(refreshObject{old, "old", false}))
			data := make([]byte, 7)
			_, err = item.ReadAt(data, 0)
			require.NoError(t, err)
			if !open {
				require.NoError(t, item.Close(nil))
			}
			require.NoError(t, c.Rename("draft", "renamed", remote.response))
			if open {
				require.Equal(t, "old", item.o.(refreshObject).etag)
				require.NotNil(t, item.ankolePending)
				require.NoError(t, item.Close(nil))
			}
			require.Nil(t, item.ankolePending)
			require.Equal(t, "merged", item.o.(refreshObject).etag)
			require.Zero(t, item.info.Rs.Size())
			require.Equal(t, int64(25), item.info.Size)
		})
	}
}
