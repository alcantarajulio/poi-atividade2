package handler

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
)

func get(t *testing.T, h http.HandlerFunc, target string) (*httptest.ResponseRecorder, map[string]any) {
	t.Helper()
	rec := httptest.NewRecorder()
	h(rec, httptest.NewRequest(http.MethodGet, target, nil))
	var body map[string]any
	if err := json.NewDecoder(rec.Body).Decode(&body); err != nil {
		t.Fatalf("failed to decode response: %v", err)
	}
	return rec, body
}

func TestCPU(t *testing.T) {
	h := CPU(CPUConfig{DefaultIter: 10, MaxIter: 1000})

	rec, body := get(t, h, "/cpu?iter=1")
	if rec.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d", rec.Code)
	}
	want := sha256.Sum256([]byte("poi"))
	if body["digest"] != hex.EncodeToString(want[:8]) {
		t.Errorf("iter=1 should be a single sha256, got digest %v", body["digest"])
	}

	_, body = get(t, h, "/cpu")
	if body["iter"] != float64(10) {
		t.Errorf("expected default iter 10, got %v", body["iter"])
	}
}

func TestCPUInvalidIter(t *testing.T) {
	h := CPU(CPUConfig{DefaultIter: 10, MaxIter: 1000})
	for _, q := range []string{"abc", "0", "1001"} {
		rec, _ := get(t, h, "/cpu?iter="+q)
		if rec.Code != http.StatusBadRequest {
			t.Errorf("iter=%s: expected status 400, got %d", q, rec.Code)
		}
	}
}

func TestMem(t *testing.T) {
	h := Mem(MemConfig{DefaultMB: 1, MaxMB: 8, DefaultHoldMS: 0, MaxHoldMS: 10})

	rec, body := get(t, h, "/mem?mb=2&hold=1")
	if rec.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d", rec.Code)
	}
	if body["mb"] != float64(2) || body["hold_ms"] != float64(1) {
		t.Errorf("unexpected body: %v", body)
	}
}

func TestMemInvalidParams(t *testing.T) {
	h := Mem(MemConfig{DefaultMB: 1, MaxMB: 8, DefaultHoldMS: 0, MaxHoldMS: 10})
	for _, q := range []string{"mb=0", "mb=9", "hold=11", "hold=-1"} {
		rec, _ := get(t, h, "/mem?"+q)
		if rec.Code != http.StatusBadRequest {
			t.Errorf("%s: expected status 400, got %d", q, rec.Code)
		}
	}
}

func TestIO(t *testing.T) {
	dir := t.TempDir()
	h := IO(IOConfig{Dir: dir, DefaultKB: 4, MaxKB: 1024})

	for _, q := range []string{"kb=100&fsync=1", "kb=100&fsync=0"} {
		rec, body := get(t, h, "/io?"+q)
		if rec.Code != http.StatusOK {
			t.Fatalf("%s: expected status 200, got %d (%v)", q, rec.Code, body)
		}
		if body["kb"] != float64(100) {
			t.Errorf("%s: unexpected kb: %v", q, body["kb"])
		}
	}

	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Errorf("expected request files to be removed, found %d", len(entries))
	}
}

func TestIOInvalidParams(t *testing.T) {
	h := IO(IOConfig{Dir: t.TempDir(), DefaultKB: 4, MaxKB: 1024})
	for _, q := range []string{"kb=0", "kb=1025", "fsync=2"} {
		rec, _ := get(t, h, "/io?"+q)
		if rec.Code != http.StatusBadRequest {
			t.Errorf("%s: expected status 400, got %d", q, rec.Code)
		}
	}
}

func TestIOMissingDir(t *testing.T) {
	h := IO(IOConfig{Dir: "/nonexistent/poi", DefaultKB: 4, MaxKB: 1024})
	rec, _ := get(t, h, "/io")
	if rec.Code != http.StatusInternalServerError {
		t.Errorf("expected status 500, got %d", rec.Code)
	}
}

func TestReadyz(t *testing.T) {
	rec, _ := get(t, Readyz(nil), "/readyz")
	if rec.Code != http.StatusOK {
		t.Errorf("expected status 200, got %d", rec.Code)
	}

	rec, _ = get(t, Readyz(func() error { return errors.New("disk full") }), "/readyz")
	if rec.Code != http.StatusServiceUnavailable {
		t.Errorf("expected status 503, got %d", rec.Code)
	}

	rec, _ = get(t, Readyz(DirWritable(t.TempDir())), "/readyz")
	if rec.Code != http.StatusOK {
		t.Errorf("expected writable dir to be ready, got %d", rec.Code)
	}
}
