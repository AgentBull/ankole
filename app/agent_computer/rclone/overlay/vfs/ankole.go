package vfs

import (
	"context"
	"path"
	"strings"
	"syscall"
	"time"

	"github.com/rclone/rclone/fs"
	"github.com/rclone/rclone/internal/ankole"
)

func (vfs *VFS) ankoleAttach() {
	remote, ok := vfs.f.(interface{ AnkoleState() *ankole.State })
	if !ok || remote.AnkoleState() == nil {
		return
	}
	state := remote.AnkoleState()
	state.Invalidate = func(names []string) {
		vfs.ankoleNegative.Range(func(key, value any) bool { vfs.ankoleNegative.Delete(key); return true })
		if vfs.cache != nil {
			vfs.cache.AnkoleInvalidate(names)
		}
		selected := map[string]bool{}
		for _, name := range names {
			selected[name] = true
		}
		found := false
		vfs.root.walk(func(d *Dir) {
			changed := len(names) == 0 || selected[d.path] || selected["id:"+AnkoleEntryID(d.entry)]
			for _, node := range d.items {
				if _, isDir := node.(*Dir); isDir {
					continue
				}
				if selected[node.Path()] || selected["id:"+AnkoleEntryID(node.DirEntry())] {
					changed = true
				}
			}
			if changed {
				d.read = time.Time{}
				found = true
			}
		})
		if !found {
			vfs.root.mu.Lock()
			vfs.root.read = time.Time{}
			vfs.root.mu.Unlock()
		}
		if vfs.ankoleNotify != nil {
			vfs.ankoleNotify(names)
		}
	}
	state.Prioritize = func(names []string) {
		if vfs.cache != nil {
			vfs.cache.AnkolePrioritize(names)
		}
	}
}

func (vfs *VFS) ankoleVirtualPath(name string) bool {
	remote, ok := vfs.f.(interface{ AnkoleState() *ankole.State })
	return ok && remote.AnkoleState() != nil &&
		(ankole.Tabular(name) || strings.Contains(name, "._aapp/"))
}

func AnkoleEntryID(entry fs.DirEntry) string {
	if entry, ok := entry.(interface{ ID() string }); ok {
		return entry.ID()
	}
	return ""
}

func (vfs *VFS) AnkoleDirty(name string) bool { return vfs.cache != nil && vfs.cache.AnkoleDirty(name) }

func (vfs *VFS) AnkoleRefreshExport(node Node) error {
	file, ok := node.(*File)
	if !ok || !strings.Contains(file.Path(), "._abase/") || !strings.Contains(file.Path(), "/.export/") {
		return nil
	}
	remote, ok := vfs.f.(interface {
		AnkoleStat(context.Context, string) (fs.DirEntry, error)
	})
	if !ok {
		return nil
	}
	entry, err := remote.AnkoleStat(vfs.ctx, file.Path())
	if err != nil {
		return err
	}
	if object, ok := entry.(fs.Object); ok {
		file.setObject(object)
	}
	return nil
}

func (vfs *VFS) AnkoleNotify(callback func([]string)) { vfs.ankoleNotify = callback }

func (d *Dir) ankoleStat(leaf string) (Node, error) {
	remote, ok := d.f.(interface {
		AnkoleStat(context.Context, string) (fs.DirEntry, error)
	})
	if !ok {
		return nil, ENOENT
	}
	name := path.Join(d.path, leaf)
	if !strings.Contains(name, "._abase/") && !strings.HasSuffix(name, "._asub") {
		return nil, ENOENT
	}
	if until, ok := d.vfs.ankoleNegative.Load(name); ok && time.Now().Before(until.(time.Time)) {
		return nil, ENOENT
	}
	entry, err := remote.AnkoleStat(d.vfs.ctx, name)
	if err != nil {
		if err == fs.ErrorObjectNotFound || err == fs.ErrorDirNotFound {
			d.vfs.ankoleNegative.Store(name, time.Now().Add(5*time.Second))
			return nil, ENOENT
		}
		return nil, err
	}
	var node Node
	switch entry := entry.(type) {
	case fs.Directory:
		node = newDir(d.vfs, d.f, d, entry)
	case fs.Object:
		node = newFile(d, d.path, entry, leaf)
	}
	if node == nil {
		return nil, ENOENT
	}
	d.addObject(node)
	return node, nil
}

func (vfs *VFS) AnkoleCopyFileRange(ctx context.Context, from, to Handle, length uint64) (uint32, error) {
	source, ok := from.(*RWFileHandle)
	target, targetOK := to.(*RWFileHandle)
	if !ok || !targetOK || source.file == target.file || vfs.cache == nil || vfs.cache.AnkoleState() == nil {
		return 0, syscall.EOPNOTSUPP
	}
	name := target.Node().Path()
	for _, suffix := range []string{"._adoc.md", "._awiki.md", "._asub", "._abase", "._aapp"} {
		if strings.HasSuffix(name, suffix) {
			return 0, syscall.EOPNOTSUPP
		}
	}
	if vfs.ankoleVirtualPath(name) {
		return 0, syscall.EOPNOTSUPP
	}
	source.mu.Lock()
	err := source.openPending()
	var object fs.Object
	if err == nil {
		object, err = source.item.AnkoleCopySource(ctx, source.file.setObject)
	}
	source.mu.Unlock()
	if err != nil {
		return 0, err
	}
	etag, ordinary := object.(interface{ AnkoleETag() string })
	if !ordinary || !strings.HasPrefix(etag.AnkoleETag(), "\"file:") || object.Size() < 0 || uint64(object.Size()) > min(length, uint64(^uint32(0))) {
		return 0, syscall.EOPNOTSUPP
	}
	target.mu.Lock()
	defer target.mu.Unlock()
	if target.readOnly() {
		return 0, syscall.EACCES
	}
	if err = target.openPending(); err != nil {
		return 0, err
	}
	copied, err := target.item.AnkoleCopyFrom(ctx, object)
	if err != nil {
		return 0, err
	}
	target.file.setObject(copied)
	target.updateSize()
	return uint32(copied.Size()), nil
}
