package handler

import (
	"net/http"
	"runtime"
	"time"
)

const pageSize = 4096

type MemConfig struct {
	DefaultMB     int
	MaxMB         int
	DefaultHoldMS int
	MaxHoldMS     int
}

func Mem(cfg MemConfig) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		mb, err := intParam(r, "mb", cfg.DefaultMB, 1, cfg.MaxMB)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
			return
		}
		hold, err := intParam(r, "hold", cfg.DefaultHoldMS, 0, cfg.MaxHoldMS)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
			return
		}

		start := time.Now()
		buf := make([]byte, mb<<20)
		for i := 0; i < len(buf); i += pageSize {
			buf[i] = byte(i >> 12)
		}
		allocMS := msSince(start)

		scanStart := time.Now()
		var checksum uint64
		for i := 0; i < len(buf); i += 64 {
			checksum += uint64(buf[i])
		}
		scanMS := msSince(scanStart)

		time.Sleep(time.Duration(hold) * time.Millisecond)
		runtime.KeepAlive(buf)

		writeJSON(w, http.StatusOK, map[string]any{
			"mb":         mb,
			"hold_ms":    hold,
			"alloc_ms":   allocMS,
			"scan_ms":    scanMS,
			"checksum":   checksum,
			"elapsed_ms": msSince(start),
		})
	}
}
