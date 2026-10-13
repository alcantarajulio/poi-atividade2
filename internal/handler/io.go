package handler

import (
	"fmt"
	"hash/crc32"
	"io"
	"math/rand"
	"net/http"
	"os"
	"time"
)

type IOConfig struct {
	Dir       string
	DefaultKB int
	MaxKB     int
}

func IO(cfg IOConfig) http.HandlerFunc {
	block := make([]byte, 64<<10)
	rand.New(rand.NewSource(42)).Read(block)

	return func(w http.ResponseWriter, r *http.Request) {
		kb, err := intParam(r, "kb", cfg.DefaultKB, 1, cfg.MaxKB)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
			return
		}
		doSync, err := intParam(r, "fsync", 1, 0, 1)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
			return
		}

		start := time.Now()
		res, err := writeSyncRead(cfg.Dir, block, kb<<10, doSync == 1)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
			return
		}
		res["kb"] = kb
		res["fsync"] = doSync == 1
		res["elapsed_ms"] = msSince(start)
		writeJSON(w, http.StatusOK, res)
	}
}

func writeSyncRead(dir string, block []byte, size int, doSync bool) (map[string]any, error) {
	f, err := os.CreateTemp(dir, "req-*.bin")
	if err != nil {
		return nil, fmt.Errorf("create: %w", err)
	}
	defer func() {
		_ = f.Close()
		_ = os.Remove(f.Name())
	}()

	t := time.Now()
	for left := size; left > 0; {
		n := min(len(block), left)
		if _, err := f.Write(block[:n]); err != nil {
			return nil, fmt.Errorf("write: %w", err)
		}
		left -= n
	}
	writeMS := msSince(t)

	t = time.Now()
	if doSync {
		if err := f.Sync(); err != nil {
			return nil, fmt.Errorf("fsync: %w", err)
		}
	}
	syncMS := msSince(t)

	t = time.Now()
	if _, err := f.Seek(0, io.SeekStart); err != nil {
		return nil, fmt.Errorf("seek: %w", err)
	}
	h := crc32.NewIEEE()
	if _, err := io.Copy(h, f); err != nil {
		return nil, fmt.Errorf("read: %w", err)
	}
	readMS := msSince(t)

	return map[string]any{
		"write_ms": writeMS,
		"fsync_ms": syncMS,
		"read_ms":  readMS,
		"crc32":    h.Sum32(),
	}, nil
}

func DirWritable(dir string) func() error {
	return func() error {
		f, err := os.CreateTemp(dir, "ready-*")
		if err != nil {
			return err
		}
		name := f.Name()
		if err := f.Close(); err != nil {
			return err
		}
		return os.Remove(name)
	}
}
