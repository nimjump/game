//go:build windows

package game

// sysstats_windows.go — Windows build stub. The admin panel only needs this
// on the production server (Linux), but the backend still has to compile
// cleanly on a Windows dev machine (`go run .`), so this returns zeros
// instead of pulling in a Windows-specific API dependency for something
// that's only ever actually used in production.

type SystemResources struct {
	DiskTotalBytes uint64 `json:"disk_total_bytes"`
	DiskFreeBytes  uint64 `json:"disk_free_bytes"`
	DiskUsedBytes  uint64 `json:"disk_used_bytes"`
	RAMTotalBytes  uint64 `json:"ram_total_bytes"`
	RAMFreeBytes   uint64 `json:"ram_free_bytes"`
	RAMUsedBytes   uint64 `json:"ram_used_bytes"`
}

func GetSystemResources(path string) SystemResources {
	_ = path
	return SystemResources{}
}
