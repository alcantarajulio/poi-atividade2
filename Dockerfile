FROM golang:1.26-alpine AS build
ARG APP=cpu
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /app-bin ./cmd/${APP}

FROM alpine:3.21
COPY --from=build /app-bin /app
ENV PORT=8080
EXPOSE 8080
ENTRYPOINT ["/app"]
