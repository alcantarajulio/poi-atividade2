# Uma imagem por app: docker build --build-arg APP=cpu|mem|io -t poi-cpu .
# O Go compila para a arquitetura alvo na plataforma do build, então gerar a
# imagem linux/amd64 da VM num Mac arm64 não precisa de emulação.
FROM --platform=$BUILDPLATFORM golang:1.26-alpine AS build
ARG APP=cpu
ARG TARGETOS
ARG TARGETARCH
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY cmd ./cmd
COPY internal ./internal
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags="-s -w" -o /out/app ./cmd/${APP}

FROM alpine:3.22
ARG APP=cpu
LABEL org.opencontainers.image.title="poi-${APP}"
COPY --from=build /out/app /usr/local/bin/app
USER 10001:10001
ENV PORT=8080
EXPOSE 8080
HEALTHCHECK --interval=15s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -q -O /dev/null "http://127.0.0.1:${PORT}/livez" || exit 1
ENTRYPOINT ["/usr/local/bin/app"]
