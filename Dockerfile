# Single-stage build+run on Swift image so the runtime libs exist
FROM swift:5.10-jammy

WORKDIR /app

# Speed up dependency resolution
COPY Package.* ./
RUN swift package resolve

# Copy sources and build release
COPY Sources ./Sources
RUN swift build -c release --product Run

# Render provides PORT; Vapor must bind 0.0.0.0
ENV PORT=8080
EXPOSE 8080

CMD [ "bash", "-lc", ".build/release/Run serve --env production --hostname 0.0.0.0 --port ${PORT}" ]
