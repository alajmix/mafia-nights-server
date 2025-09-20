# Build image
FROM swift:5.10-jammy as build
WORKDIR /app
COPY . .
RUN swift build -c release --static-swift-stdlib

# Runtime image
FROM ubuntu:22.04
WORKDIR /run
COPY --from=build /app/.build/release/MafiaServer /run/MafiaServer
ENV PORT=8080
EXPOSE 8080
CMD ["./MafiaServer"]
