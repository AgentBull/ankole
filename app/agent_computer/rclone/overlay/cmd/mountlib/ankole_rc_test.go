package mountlib_test

import (
	"context"
	"errors"
	"testing"
	"time"

	_ "github.com/rclone/rclone/backend/local"
	"github.com/rclone/rclone/cmd/mountlib"
	"github.com/rclone/rclone/fs/rc"
	"github.com/rclone/rclone/vfs"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// A FUSE unmount can wait for another mount namespace to drop its copy of the
// mount. Other mount calls must keep working while that unmount waits.
func TestAnkoleUnmountDoesNotHoldMountLock(t *testing.T) {
	ctx := context.Background()
	unmounting := make(chan struct{})
	release := make(chan error)
	mountlib.AddRc("ankole-blocking-unmount", func(_ *vfs.VFS, mountPoint string, _ *mountlib.Options) (<-chan error, func() error, string, error) {
		return make(chan error), func() error {
			unmounting <- struct{}{}
			return <-release
		}, mountPoint, nil
	})
	mount := rc.Calls.Get("mount/mount")
	unmount := rc.Calls.Get("mount/unmount")
	list := rc.Calls.Get("mount/listmounts")
	mountPoint := t.TempDir()
	mountPoints := func() []mountlib.MountInfo {
		listed := make(chan rc.Params, 1)
		go func() {
			out, err := list.Fn(ctx, rc.Params{})
			assert.NoError(t, err)
			listed <- out
		}()
		select {
		case out := <-listed:
			var mounts []mountlib.MountInfo
			require.NoError(t, out.GetStruct("mountPoints", &mounts))
			return mounts
		case <-time.After(5 * time.Second):
			t.Fatal("mount/listmounts waited for an unmount in progress")
			return nil
		}
	}

	_, err := mount.Fn(ctx, rc.Params{"fs": t.TempDir(), "mountPoint": mountPoint, "mountType": "ankole-blocking-unmount"})
	require.NoError(t, err)
	require.Len(t, mountPoints(), 1)

	// A failed unmount leaves the mount listed so that the caller can retry it.
	failed := make(chan error, 1)
	go func() {
		_, err := unmount.Fn(ctx, rc.Params{"mountPoint": mountPoint})
		failed <- err
	}()
	<-unmounting
	assert.Empty(t, mountPoints())
	release <- errors.New("device or resource busy")
	require.Error(t, <-failed)
	require.Len(t, mountPoints(), 1)

	done := make(chan error, 1)
	go func() {
		_, err := unmount.Fn(ctx, rc.Params{"mountPoint": mountPoint})
		done <- err
	}()
	<-unmounting
	assert.Empty(t, mountPoints())
	release <- nil
	require.NoError(t, <-done)
	assert.Empty(t, mountPoints())
}
