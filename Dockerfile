# syntax=docker/dockerfile:1

# Build the Phase-1 Java service.
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /build

COPY phase1-testcontainers/pom.xml ./pom.xml
RUN mvn -q -DskipTests dependency:go-offline

COPY phase1-testcontainers/src ./src
RUN mvn -q clean package -DskipTests

# Runtime.
FROM eclipse-temurin:21-jre
WORKDIR /app

COPY --from=build /build/target/phase1-app.jar /app/phase1-app.jar
COPY --from=build /build/target/lib /app/lib

# Freeze the exact governed migration source into this validator image.
COPY migrations /app/migrations

# Fail the image build if the governed source is missing.
RUN test -d /app/migrations \
    && test "$(find /app/migrations -type f -name '*.sql' | wc -l)" -gt 0

ENV PORT=8081
ENV MIGRATION_DIR=/app/migrations
ENV DATABASE_WRITES=1
ENV DB_WRITE_PARALLELISM=1
ENV MIGRATION_BATCH_SIZE=1
ENV TESTCONTAINERS_POSTGRES_IMAGE=postgres:17.6

EXPOSE 8081

ENTRYPOINT ["java", "-cp", "/app/phase1-app.jar:/app/lib/*", "com.cylindermanagement.mcp.Phase1TestcontainersServer"]
