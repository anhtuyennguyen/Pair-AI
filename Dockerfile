# Stage 1: Biên dịch ứng dụng Swift Vapor
FROM swift:5.10-jammy as builder
WORKDIR /build

COPY Package.resolved Package.swift ./
RUN swift package resolve

COPY . .
RUN swift build -c release --static-swift-stdlib

# Stage 2: Môi trường Runtime siêu nhẹ
FROM ubuntu:22.04
RUN apt-get update && apt-get install -y \
    ca-certificates libcurl4 libxml2 tzdata \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy toàn bộ file thực thi đã release sang Stage 2
COPY --from=builder /build/.build/release/ /app/

EXPOSE 8080
ENTRYPOINT ["./Pair-AI"]
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]