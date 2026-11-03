//go:build ankole

package main

import (
	_ "github.com/rclone/rclone/backend/local"
	_ "github.com/rclone/rclone/backend/webdav"
	"github.com/rclone/rclone/cmd"
	_ "github.com/rclone/rclone/cmd/mount2"
	_ "github.com/rclone/rclone/cmd/rcd"
)

func main() { cmd.Main() }
