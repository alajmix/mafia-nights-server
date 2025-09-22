# ---------- Build image ----------
FROM swift:5.10-jammy AS build
WORKDIR /app

COPY Package.swift ./
RUN swift package resolve

COPY Sources ./Sources
RUN swift build -c release --product Run

# ---------- Runtime image ----------
FROM ubuntu:22.04 AS runtime
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y     libatomic1 libicu70 libxml2 libsqlite3-0 libz3-dev zlib1g tzdata ca-certificates     && rm -rf /var/lib/apt/lists/*

WORKDIR /run
COPY --from=build /app/.build/release/Run ./Run

ENV PORT=8080
EXPOSE 8080

CMD ["bash", "-lc", "./Run serve --env production --hostname 0.0.0.0 --port ${PORT}"]
