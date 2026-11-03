package vfscache

import (
	"context"
	"encoding/json"
	"io/fs"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	rfs "github.com/rclone/rclone/fs"
	"github.com/rclone/rclone/fs/config"
	"github.com/rclone/rclone/internal/ankole"
	"github.com/rclone/rclone/lib/atexit"
	"golang.org/x/sys/unix"
)

var ankoleCaches sync.Map
var ankoleDisk sync.Mutex
var ankoleQuota = sync.OnceFunc(func() {
	ankoleReadCold()
	ctx, cancel := context.WithCancel(context.Background())
	atexit.Register(cancel)
	go ankoleRunQuota(ctx)
})

type coldFile struct {
	data, meta string
	accessed   time.Time
	size       int64
	dirty      bool
}

var ankoleCold []*coldFile
var capacityPattern = regexp.MustCompile(`^([+-]?[0-9]+(?:\.[0-9]*)?|[+-]?\.[0-9]+)([eE][+-]?[0-9]+|[numkKMGTPE]i?)?$`)

// Kubernetes emptyDir and directory-backed PVC limits do not change statfs.
// This is the provider's declared capacity, not an independent operator knob.
func ankoleCapacity(raw string) int64 {
	match := capacityPattern.FindStringSubmatch(raw)
	if match == nil {
		return 0
	}
	amount, err := strconv.ParseFloat(match[1], 64)
	if err != nil {
		return 0
	}
	suffix := match[2]
	if len(suffix) > 1 && (suffix[0] == 'e' || suffix[0] == 'E') && suffix[1] != 'i' {
		exponent, err := strconv.Atoi(suffix[1:])
		if err != nil {
			return 0
		}
		amount *= math.Pow10(exponent)
	} else if len(suffix) > 0 {
		exponent := map[byte]int{'n': -3, 'u': -2, 'm': -1, 'k': 1, 'K': 1, 'M': 2, 'G': 3, 'T': 4, 'P': 5, 'E': 6}[suffix[0]]
		base := 1000.0
		if strings.HasSuffix(suffix, "i") {
			base = 1024
		}
		amount *= math.Pow(base, float64(exponent))
	}
	if amount <= 0 || amount >= math.MaxInt64 {
		return 0
	}
	return int64(math.Ceil(amount))
}

func ankoleReadCold() {
	root := filepath.Join(config.GetCacheDir(), "vfsMeta")
	_ = filepath.WalkDir(root, func(meta string, entry fs.DirEntry, err error) error {
		if err != nil || entry.IsDir() {
			return nil
		}
		raw, err := os.ReadFile(meta)
		if err != nil {
			return nil
		}
		var info Info
		if json.Unmarshal(raw, &info) != nil {
			return nil
		}
		rel, err := filepath.Rel(root, meta)
		if err != nil {
			return nil
		}
		ankoleCold = append(ankoleCold, &coldFile{
			data:     filepath.Join(config.GetCacheDir(), "vfs", rel),
			meta:     meta,
			accessed: info.ATime,
			size:     info.Rs.Size(),
			dirty:    info.Dirty,
		})
		return nil
	})
}

func ankoleCacheOpening(remote rfs.Fs) func() {
	if owner, ok := remote.(interface{ AnkoleState() *ankole.State }); ok && owner.AnkoleState() != nil {
		ankoleDisk.Lock()
		return ankoleDisk.Unlock
	}
	return func() {}
}

func (c *Cache) AnkoleRegister() {
	if c.AnkoleState() == nil {
		return
	}
	var stat unix.Statfs_t
	if unix.Statfs(config.GetCacheDir(), &stat) == nil {
		capacity := int64(stat.Blocks) * int64(stat.Bsize)
		if declared := ankoleCapacity(os.Getenv("ANKOLE_WORKER_CACHE_CAPACITY")); declared > 0 {
			capacity = min(capacity, declared)
		}
		ankole.SetDiskCapacity(capacity)
	}
	// Keep the upstream cache index after an idle unmount. Its clean sparse
	// files still consume this volume; a remount replaces the same root entry.
	c.writeback.ReserveTransfer()
	ankoleCaches.Store(c.root, c)
	ankoleQuota()
}

func ankoleRunQuota(ctx context.Context) {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			ankoleTrim()
		}
	}
}

func (c *Cache) AnkoleDirty(name string) bool {
	c.mu.Lock()
	item := c.item[name]
	c.mu.Unlock()
	return item != nil && item.IsDirty()
}

// All active mounts share the volume budget. Reset delegates sparse accounting
// and open/dirty exclusion to rclone, so no separate cache index is needed.
func ankoleTrim() {
	ankoleDisk.Lock()
	defer ankoleDisk.Unlock()
	type candidate struct {
		item     *Item
		accessed time.Time
		remove   func() int64
	}
	var files []candidate
	var used, limit, free, capacity int64
	ankoleCaches.Range(func(_, value any) bool {
		c := value.(*Cache)
		var stat unix.Statfs_t
		if unix.Statfs(c.root, &stat) == nil {
			capacity = int64(stat.Blocks) * int64(stat.Bsize)
			if declared := ankoleCapacity(os.Getenv("ANKOLE_WORKER_CACHE_CAPACITY")); declared > 0 {
				capacity = min(capacity, declared)
			}
			free = int64(stat.Bavail) * int64(stat.Bsize)
			if limit == 0 || capacity*7/10 < limit {
				limit = capacity * 7 / 10
			}
		}
		c.mu.Lock()
		for _, item := range c.item {
			item.mu.Lock()
			bytes := item.info.Rs.Size()
			used += bytes
			if !item.info.Dirty {
				files = append(files, candidate{item: item, accessed: item.info.ATime})
			}
			item.mu.Unlock()
		}
		c.mu.Unlock()
		return true
	})
	// Reuse persisted upstream metadata for scopes not mounted in this daemon.
	for _, cold := range ankoleCold {
		if cold.size == 0 {
			continue
		}
		known := false
		ankoleCaches.Range(func(key, value any) bool {
			root := key.(string)
			known = cold.data == root || strings.HasPrefix(cold.data, root+string(os.PathSeparator))
			return !known
		})
		if known {
			continue
		}
		used += cold.size
		if !cold.dirty {
			files = append(files, candidate{accessed: cold.accessed, remove: func() int64 {
				if err := os.Remove(cold.data); err != nil && !os.IsNotExist(err) {
					return 0
				}
				_ = os.Remove(cold.meta)
				freed := cold.size
				cold.size = 0
				return freed
			}})
		}
	}
	if limit == 0 {
		return
	}
	reclaim := max(used-limit, capacity*3/10-free)
	if reclaim <= 0 {
		return
	}
	slices.SortFunc(files, func(a, b candidate) int { return a.accessed.Compare(b.accessed) })
	for _, file := range files {
		if reclaim <= 0 {
			break
		}
		if file.remove != nil {
			reclaim -= file.remove()
		} else {
			_, freed, _ := file.item.Reset()
			reclaim -= freed
		}
	}
}
