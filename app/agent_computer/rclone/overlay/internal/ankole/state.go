// Package ankole owns the small WebDAV writeback extension to rclone's VFS.
// rclone still owns sparse files, downloaders, directory handles and uploads.
package ankole

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/google/uuid"
	"github.com/rclone/rclone/fs/rc"
)

type Write struct {
	state           *State
	BaseFingerprint string
	BaseSize        int64
	BaseETag        string
	RequestID       string
	RequestMillis   int64
	Seq             uint64
	UploadSeq       uint64
	Size            int64
	Path            string
	NodeID          string
	Failure         string
	Recovery        string
	Closed          bool
	Done            bool
	Replace         bool
	BaseRecord      json.RawMessage
	Priority        bool
}

func (w *Write) MarshalJSON() ([]byte, error) {
	if w.state != nil {
		w.state.mu.Lock()
		defer w.state.mu.Unlock()
	}
	type encoded Write
	return json.Marshal((*encoded)(w))
}
func (s *State) Snapshot(w *Write) Write {
	s.mu.Lock()
	defer s.mu.Unlock()
	return snapshot(w)
}

func snapshot(w *Write) Write {
	snapshot := *w
	snapshot.state = nil
	snapshot.BaseRecord = slices.Clone(w.BaseRecord)
	return snapshot
}

// UploadSnapshot binds retries of one request ID to its first local revision.
// A lost reply must not make later edits look like part of that receipt.
func (s *State) UploadSnapshot(w *Write) Write {
	s.mu.Lock()
	defer s.mu.Unlock()
	if w.UploadSeq == 0 {
		w.UploadSeq = w.Seq
	}
	return snapshot(w)
}

// NextUpload keeps the pending write (and its flush waiters and capacity) while
// assigning a fresh receipt to edits made after the acknowledged upload.
func (s *State) NextUpload(w *Write, etag string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	w.BaseETag = etag
	w.BaseFingerprint = ""
	w.BaseSize = 0
	w.RequestID = uuid.NewString()
	w.RequestMillis = time.Now().UnixMilli()
	w.UploadSeq = 0
}
func (s *State) SetBaseline(w *Write, baseline []byte) {
	s.mu.Lock()
	w.BaseRecord = slices.Clone(baseline)
	s.mu.Unlock()
}

func (s *State) SetFingerprint(w *Write, fingerprint string, size int64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if w.BaseFingerprint == "" {
		w.BaseFingerprint = fingerprint
		w.BaseSize = size
	}
}

type Transport interface {
	SetToken(string)
}

type State struct {
	mu          sync.Mutex
	remote      Transport
	reads       map[string]string
	records     map[string]json.RawMessage
	writes      map[string]*Write
	seq         uint64
	Recovery    string
	Invalidate  func([]string)
	Prioritize  func([]string)
	uploadLimit atomic.Int64
}

var states sync.Map
var dirtyBytes atomic.Int64
var diskDirtyLimit atomic.Int64
var diskFileLimit atomic.Int64

func SetDiskCapacity(capacity int64) {
	if capacity > 0 {
		diskDirtyLimit.Store(min(1<<30, capacity*7/10))
		diskFileLimit.Store(capacity * 7 / 20)
	}
}

// Backpressure waits only when a closed upload can make progress. Open handles
// must be able to close even when their combined working set reaches the limit.
func reserve(ctx context.Context, size int64) error {
	if size <= 0 {
		return ctx.Err()
	}
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		used := dirtyBytes.Load()
		hard := diskDirtyLimit.Load()
		if hard == 0 {
			hard = 1 << 30
		}
		soft := min(int64(512<<20), hard/2)
		drainable := false
		if used+size > soft {
			states.Range(func(_, value any) bool {
				s := value.(*State)
				s.mu.Lock()
				for _, w := range s.writes {
					if w.Closed && !w.Done {
						drainable = true
						break
					}
				}
				s.mu.Unlock()
				return !drainable
			})
		}
		if !drainable {
			if used+size > hard {
				return syscall.ENOSPC
			}
			if dirtyBytes.CompareAndSwap(used, used+size) {
				return nil
			}
			continue
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(50 * time.Millisecond):
		}
	}
}

func New(name string, remote Transport) *State {
	s := &State{remote: remote, reads: map[string]string{}, records: map[string]json.RawMessage{}, writes: map[string]*Write{}}
	s.uploadLimit.Store(100 << 20)
	states.Store(name, s)
	return s
}

func (s *State) SetUploadLimit(limit int64) {
	if limit > 0 {
		s.uploadLimit.Store(limit)
	}
}
func (s *State) FileLimit(name string) int64 {
	limit := s.uploadLimit.Load()
	if disk := diskFileLimit.Load(); disk > 0 {
		limit = min(limit, disk)
	}
	if strings.HasSuffix(name, "._awiki.md") || strings.HasSuffix(name, "._adoc.md") || Tabular(name) {
		limit = min(limit, 100<<20)
	}
	return limit
}
func (s *State) ForgetRead(name string) {
	s.mu.Lock()
	delete(s.reads, name)
	s.mu.Unlock()
}

func (s *State) ReadOpened(name, etag string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if etag != "" {
		s.reads[name] = etag
	}
}

func (s *State) ReadETag(name string) string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.reads[name]
}

func Record(name string) bool {
	return Tabular(name) && strings.HasPrefix(path.Base(name), "rec_") && strings.HasSuffix(name, ".json")
}
func Sink(name string) bool {
	return strings.Contains(name, "._abase/") && (strings.HasSuffix(name, "/.import/append.csv") || strings.HasSuffix(name, "/.import/append.jsonl"))
}
func (s *State) RecordOpened(name string, data []byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.records[name] = slices.Clone(data)
}
func (s *State) RecordBaseline(name string) json.RawMessage {
	s.mu.Lock()
	defer s.mu.Unlock()
	return slices.Clone(s.records[name])
}
func (s *State) WaitSink(ctx context.Context, name string) error {
	if !Sink(name) {
		return nil
	}
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		s.mu.Lock()
		w := s.writes[name]
		wait := w != nil && w.Closed && !w.Done
		s.mu.Unlock()
		if !wait {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(20 * time.Millisecond):
		}
	}
}

var uploads = make(chan struct{}, 4)
var backgroundUploads = make(chan struct{}, 3)

// One transfer slot remains available for an explicit delivery flush.
func (s *State) Upload(ctx context.Context, w *Write) (func(), error) {
	for {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		s.mu.Lock()
		priority := w.Priority
		s.mu.Unlock()
		background := false
		if !priority {
			select {
			case backgroundUploads <- struct{}{}:
				background = true
			default:
			}
		}
		if priority || background {
			select {
			case uploads <- struct{}{}:
				return func() {
					<-uploads
					if background {
						<-backgroundUploads
					}
				}, nil
			default:
				if background {
					<-backgroundUploads
				}
			}
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(20 * time.Millisecond):
		}
	}
}

func (s *State) Begin(ctx context.Context, name, etag string, previous *Write, size int64) (*Write, error) {
	if size > s.FileLimit(name) {
		return nil, syscall.EFBIG
	}
	s.mu.Lock()
	if previous != nil && previous.Failure != "" {
		s.mu.Unlock()
		return nil, syscall.ESTALE
	}
	if previous != nil && !previous.Done {
		growth := max(size-previous.Size, 0)
		previous.Closed = false
		s.mu.Unlock()
		if err := reserve(ctx, growth); err != nil {
			return nil, err
		}
		s.mu.Lock()
		previous.Size += growth
		previous.Closed = false
		s.seq++
		previous.Seq = s.seq
		s.mu.Unlock()
		return previous, nil
	}
	s.mu.Unlock()
	if err := reserve(ctx, size); err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.seq++
	w := &Write{state: s, BaseETag: etag, RequestID: uuid.NewString(), RequestMillis: time.Now().UnixMilli(), Seq: s.seq, Size: size, Path: name}
	s.writes[name] = w
	return w, nil
}

func (s *State) Restore(w *Write) {
	if w == nil || w.Done {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	w.state = s
	if s.writes[w.Path] == nil {
		s.writes[w.Path] = w
		dirtyBytes.Add(w.Size)
	}
	s.seq = max(s.seq, w.Seq)
}

func (s *State) Closed(w *Write) {
	if w != nil {
		s.mu.Lock()
		w.Closed = true
		s.mu.Unlock()
	}
}
func (s *State) Complete(w *Write, nodeID string) {
	if w == nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if !w.Done {
		dirtyBytes.Add(-w.Size)
		w.Done = true
		w.NodeID = nodeID
		if w.Failure == "" && s.writes[w.Path] == w {
			delete(s.writes, w.Path)
		}
	}
}

func (s *State) Cancel(w *Write) {
	if w == nil {
		return
	}
	s.Complete(w, "")
}

func (s *State) WriteHeaders(name string) map[string]string {
	s.mu.Lock()
	w := s.writes[name]
	s.mu.Unlock()
	if w == nil {
		return nil
	}
	snapshot := s.Snapshot(w)
	return writeHeaders(&snapshot)
}

func (s *State) Rename(w *Write, name string) {
	if w == nil {
		return
	}
	s.mu.Lock()
	if w.Done {
		s.mu.Unlock()
		return
	}
	delete(s.writes, w.Path)
	w.Path = name
	s.seq++
	w.Seq = s.seq
	w.Replace = true
	w.BaseETag = s.reads[name]
	w.BaseRecord = slices.Clone(s.records[name])
	s.writes[name] = w
	s.mu.Unlock()
}

func (s *State) Recover(w *Write, local string, cause error) error {
	if w == nil {
		return cause
	}
	s.mu.Lock()
	recovery := s.Recovery
	s.mu.Unlock()
	if recovery == "" {
		return fmt.Errorf("recovery directory is not configured: %w", cause)
	}
	if err := os.MkdirAll(recovery, 0750); err != nil {
		return err
	}
	before := s.Snapshot(w)
	target := filepath.Join(recovery, time.Now().UTC().Format("20060102T150405.000000000")+"-"+path.Base(before.Path))
	before.Failure, before.Recovery = cause.Error(), "/drive-recovery/"+filepath.Base(target)
	encoded, err := json.Marshal(before)
	if err != nil {
		return fmt.Errorf("encode recovery metadata: %w", err)
	}
	if err := os.Rename(local, target); err != nil {
		return err
	}
	s.mu.Lock()
	w.Failure, w.Recovery = before.Failure, before.Recovery
	s.mu.Unlock()
	if err := os.Chown(target, 1000, 1000); err != nil {
		return err
	}
	if err := os.WriteFile(target+".err.json", encoded, 0640); err != nil {
		return err
	}
	if err := os.Chown(target+".err.json", 1000, 1000); err != nil {
		return err
	}
	s.Cancel(w)
	return nil
}

type writeKey struct{}

func WithWrite(ctx context.Context, w *Write) context.Context {
	if w != nil && w.state != nil {
		snapshot := w.state.Snapshot(w)
		w = &snapshot
	}
	return context.WithValue(ctx, writeKey{}, w)
}
func Headers(ctx context.Context) map[string]string {
	w, _ := ctx.Value(writeKey{}).(*Write)
	return writeHeaders(w)
}

func writeHeaders(w *Write) map[string]string {
	headers := map[string]string{}
	if w == nil {
		return headers
	}
	headers["X-Ankole-Request-Id"] = w.RequestID
	headers["X-Ankole-Request-Ts-Ms"] = fmt.Sprint(w.RequestMillis)
	if len(w.BaseRecord) > 0 {
		headers["X-Ankole-Record-Patch"] = "1"
	}
	if Tabular(w.Path) {
		return headers
	}
	if w.BaseETag == "" {
		if !w.Replace {
			headers["If-None-Match"] = "*"
		}
	} else {
		headers["If-Match"] = w.BaseETag
	}
	return headers
}

type TerminalError struct {
	Status  int
	Message string
}

func (e *TerminalError) Error() string { return fmt.Sprintf("dav %d: %s", e.Status, e.Message) }
func (e *TerminalError) Unwrap() error {
	switch e.Status {
	case 403:
		return syscall.EACCES
	case 404:
		return syscall.ENOENT
	case 409:
		return syscall.ENOTDIR
	case 412:
		return syscall.ESTALE
	case 413:
		return syscall.EFBIG
	default:
		return syscall.EINVAL
	}
}
func Terminal(err error) bool {
	_, ok := errors.AsType[*TerminalError](err)
	return ok
}
func Noise(name string) bool {
	base := path.Base(name)
	return base == ".DS_Store" || strings.HasPrefix(base, ".#") || strings.HasSuffix(base, "~") ||
		(strings.HasPrefix(base, ".~lock.") && strings.HasSuffix(base, "#")) ||
		(strings.HasPrefix(base, ".") && (strings.HasSuffix(base, ".swp") || strings.HasSuffix(base, ".swo"))) ||
		strings.HasSuffix(base, ".db-shm") || strings.HasSuffix(base, ".sqlite-shm")
}

func Tabular(name string) bool { return strings.Contains(name, "._abase/") }

func init() {
	for _, name := range []string{"configure", "sequence", "pending", "flush", "flush-paths", "invalidate", "invalidate-all-clean"} {
		rc.Add(rc.Call{Path: "ankole/" + name, Fn: func(ctx context.Context, in rc.Params) (rc.Params, error) {
			key, err := in.GetString("fs")
			if err != nil {
				return nil, err
			}
			value, ok := states.Load(key)
			if !ok {
				return nil, fmt.Errorf("unknown Ankole mount %q", key)
			}
			return value.(*State).control(ctx, name, in)
		}, Title: "Ankole Drive " + name})
	}
}

func (s *State) control(ctx context.Context, command string, in rc.Params) (rc.Params, error) {
	switch command {
	case "configure":
		if limit, err := in.GetInt64("upload_limit"); err == nil {
			s.SetUploadLimit(limit)
		}
		if token, err := in.GetString("token"); err == nil {
			s.remote.SetToken(token)
		}
		if dir, err := in.GetString("recovery"); err == nil {
			s.mu.Lock()
			s.Recovery = dir
			s.mu.Unlock()
		}
		return rc.Params{}, nil
	case "sequence":
		s.mu.Lock()
		seq := s.seq
		s.mu.Unlock()
		return rc.Params{"sequence": seq}, nil
	case "pending":
		s.mu.Lock()
		count := 0
		for _, w := range s.writes {
			if !w.Done {
				count++
			}
		}
		s.mu.Unlock()
		return rc.Params{"count": count}, nil
	case "invalidate", "invalidate-all-clean":
		var paths []string
		if command == "invalidate" {
			_ = in.GetStruct("paths", &paths)
		}
		if s.Invalidate != nil {
			s.Invalidate(paths)
			return rc.Params{}, nil
		}
		return nil, errors.New("mount is not attached")
	}
	var paths []string
	_ = in.GetStruct("paths", &paths)
	since, _ := in.GetInt64("since_seq")
	selected := map[string]*Write{}
	s.mu.Lock()
	for name, w := range s.writes {
		wanted := command == "flush" && w.Seq > uint64(since)
		for _, p := range paths {
			wanted = wanted || name == p
		}
		if wanted {
			selected[name] = w
		}
	}
	if command == "flush" && len(selected) > 64 {
		s.mu.Unlock()
		return rc.Params{"background": true}, nil
	}
	for _, w := range selected {
		w.Priority = true
	}
	s.mu.Unlock()
	names := make([]string, 0, len(selected))
	for name := range selected {
		names = append(names, name)
	}
	if s.Prioritize != nil {
		s.Prioritize(names)
	}
	for {
		complete := true
		s.mu.Lock()
		results := make([]Write, 0, len(selected))
		for _, w := range selected {
			complete = complete && w.Done
			snapshot := *w
			snapshot.state = nil
			results = append(results, snapshot)
		}
		s.mu.Unlock()
		if complete {
			return rc.Params{"files": results}, nil
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(20 * time.Millisecond):
		}
	}
}
