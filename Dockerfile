# syntax=docker/dockerfile:1

# ============================================================
# STAGE 1: BUILD PHASE-1 JAVA SERVICE
# ============================================================

FROM maven:3.9-eclipse-temurin-21 AS build

WORKDIR /build

# The Phase-1 pom.xml is at the repository root.
COPY pom.xml ./pom.xml

# Download dependencies first for better build caching.
RUN mvn -q -DskipTests dependency:go-offline

# The Phase-1 Java sources are under the repository root src/.
COPY src ./src

# Build the application and copy runtime dependencies to target/lib.
RUN mvn -q clean package -DskipTests


# ============================================================
# STAGE 2: JAVA 21 RUNTIME
# ============================================================

FROM eclipse-temurin:21-jre

WORKDIR /app

# Copy the Phase-1 application JAR.
COPY --from=build /build/target/phase1-app.jar /app/phase1-app.jar

# Copy all runtime dependency JARs.
COPY --from=build /build/target/lib /app/lib


# ============================================================
# GOVERNED FLYWAY MIGRATION SOURCE
# ============================================================

# Copy the complete governed Flyway migration set.
COPY migrations /app/migrations

# Fail closed if migrations are missing.
RUN test -d /app/migrations \
    && test "$(find /app/migrations -type f -name '*.sql' | wc -l)" -gt 0


# ============================================================
# PHASE-1 RUNTIME CONFIGURATION
# ============================================================

# Local/default Phase-1 service port.
ENV PORT=8081

# Location of the governed migration files.
ENV MIGRATION_DIR=/app/migrations

# BL-008 migration-write governance.
ENV DATABASE_WRITES=1
ENV DB_WRITE_PARALLELISM=1
ENV MIGRATION_BATCH_SIZE=1

# PostgreSQL version matching the Supabase validation target.
ENV TESTCONTAINERS_POSTGRES_IMAGE=postgres:17.6


# ============================================================
# NETWORK
# ============================================================

EXPOSE 8081


# ============================================================
# START PHASE-1 TESTCONTAINERS SERVER
# ============================================================

ENTRYPOINT ["java", "-cp", "/app/phase1-app.jar:/app/lib/*", "com.cylindermanagement.mcp.Phase1TestcontainersServer"]
