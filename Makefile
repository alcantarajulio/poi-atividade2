APPS := cpu mem io
LINUX_BIN := bin/linux-amd64
K6_VERSION := v2.3.0
K6_LINUX := tools/linux-amd64/k6

.PHONY: build build-linux lab-bundle test vet lint run-cpu run-mem run-io docker-build clean

build:
	@for app in $(APPS); do go build -o bin/$$app ./cmd/$$app || exit 1; done

build-linux:
	@for app in $(APPS); do \
		CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o $(LINUX_BIN)/$$app ./cmd/$$app || exit 1; \
	done

$(K6_LINUX):
	mkdir -p $(dir $@)
	curl -sSL https://github.com/grafana/k6/releases/download/$(K6_VERSION)/k6-$(K6_VERSION)-linux-amd64.tar.gz \
		| tar -xz -C $(dir $@) --strip-components=1 k6-$(K6_VERSION)-linux-amd64/k6

lab-bundle: build-linux $(K6_LINUX)
	tar -czf poi-lab.tar.gz $(LINUX_BIN) $(K6_LINUX) lab/lab.sh deploy monitor load \
		experiments/run.sh experiments/scenarios.conf analysis/analyze.py analysis/requirements.txt \
		docs/checklist-lcc.md docs/apresentacao.md README.md
	@ls -lh poi-lab.tar.gz

test:
	go test ./...

vet:
	go vet ./...

lint:
	golangci-lint run ./...

run-cpu:
	go run ./cmd/cpu

run-mem:
	go run ./cmd/mem

run-io:
	go run ./cmd/io

docker-build:
	@for app in $(APPS); do docker build --build-arg APP=$$app -t poi-$$app . || exit 1; done

clean:
	rm -rf bin tools poi-lab.tar.gz
