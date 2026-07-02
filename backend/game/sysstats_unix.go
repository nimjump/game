//go:build !windows

package game

// sysstats_unix.go — disk + RAM stats for the admin panel's System card.
// Linux/macOS build. Disk usage via syscall.Statfs (works on both); total
// system RAM via /proc/meminfo (Linux-only — on macOS this silently comes
// back as 0, which the admin UI just hides).

import (
	"bufio"
	"os"
	"strconv"
	"strings"
	"syscall"
)

type SystemResources struct {
	DiskTotalBytes uint64 `json:"disk_total_bytes"`
	DiskFreeBytes  uint64 `json:"disk_free_bytes"`
	DiskUsedBytes  uint64 `json:"disk_used_bytes"`
	RAMTotalBytes  uint64 `json:"ram_total_bytes"`
	RAMFreeBytes   uint64 `json:"ram_free_bytes"`
	RAMUsedBytes   uint64 `json:"ram_used_bytes"`
}

// GetSystemResources — disk stats are for the partition containing path
// (pass the DB_PATH / working directory). RAM stats are host-wide.
func GetSystemResources(path string) SystemResources {
	var res SystemResources

	if path == "" {
		path = "."
	}
	var fs syscall.Statfs_t
	if err := syscall.Statfs(path, &fs); err == nil {
		blockSize := uint64(fs.Bsize)
		res.DiskTotalBytes = fs.Blocks * blockSize
		res.DiskFreeBytes = fs.Bavail * blockSize
		if res.DiskTotalBytes >= res.DiskFreeBytes {
			res.DiskUsedBytes = res.DiskTotalBytes - res.DiskFreeBytes
		}
	}

	if f, err := os.Open("/proc/meminfo"); err == nil {
		defer f.Close()
		var totalKB, availKB uint64
		sc := bufio.NewScanner(f)
		for sc.Scan() {
			line := sc.Text()
			switch {
			case strings.HasPrefix(line, "MemTotal:"):
				totalKB = parseMeminfoKB(line)
			case strings.HasPrefix(line, "MemAvailable:"):
				availKB = parseMeminfoKB(line)
			}
		}
		res.RAMTotalBytes = totalKB * 1024
		res.RAMFreeBytes = availKB * 1024
		if res.RAMTotalBytes >= res.RAMFreeBytes {
			res.RAMUsedBytes = res.RAMTotalBytes - res.RAMFreeBytes
		}
	}

	return res
}

func parseMeminfoKB(line string) uint64 {
	fields := strings.Fields(line) // e.g. ["MemTotal:", "16384000", "kB"]
	if len(fields) < 2 {
		return 0
	}
	n, err := strconv.ParseUint(fields[1], 10, 64)
	if err != nil {
		return 0
	}
	return n
}
