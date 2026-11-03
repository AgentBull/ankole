//go:build linux || (darwin && amd64)

package mount2

import (
	"context"
	"syscall"

	fusefs "github.com/hanwen/go-fuse/v2/fs"
	"github.com/rclone/rclone/vfs"
)

// Notify both dentries and file pages. Dirty handles remain attached to their
// original inode until upload or recovery has settled them.
func (n *Node) ankoleInvalidate(names []string) {
	selected := map[string]bool{}
	for _, name := range names {
		selected[name] = true
	}
	var visit func(*fusefs.Inode)
	visit = func(inode *fusefs.Inode) {
		for name, child := range inode.Children() {
			node, ok := child.Operations().(*Node)
			if !ok || n.fsys.VFS.AnkoleDirty(node.node.Path()) {
				continue
			}
			visit(child)
			parent, ok := inode.Operations().(*Node)
			parentChanged := ok && selected["id:"+vfs.AnkoleEntryID(parent.node.DirEntry())]
			changed := len(names) == 0 || selected[node.node.Path()] || selected["id:"+vfs.AnkoleEntryID(node.node.DirEntry())]
			if changed {
				_ = child.NotifyContent(0, 0)
			}
			if changed || parentChanged {
				_ = inode.NotifyEntry(name)
			}
		}
	}
	visit(&n.Inode)
}

var _ fusefs.NodeCopyFileRanger = (*Node)(nil)

func (n *Node) CopyFileRange(ctx context.Context, fhIn fusefs.FileHandle, offIn uint64,
	out *fusefs.Inode, fhOut fusefs.FileHandle, offOut uint64, length uint64, flags uint64) (uint32, syscall.Errno) {
	source, sourceOK := fhIn.(*FileHandle)
	target, targetOK := fhOut.(*FileHandle)
	if !sourceOK || !targetOK || source.fsys != target.fsys || offIn != 0 || offOut != 0 || flags != 0 {
		return 0, syscall.EOPNOTSUPP
	}
	size, err := n.fsys.VFS.AnkoleCopyFileRange(ctx, source.h, target.h, length)
	return size, translateError(err)
}
