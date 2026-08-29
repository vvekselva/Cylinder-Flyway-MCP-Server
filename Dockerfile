# syntax=docker/dockerfile:1

# ============================================================
# STAGE 1: DOWNLOAD AND VERIFY GOVERNED FLYWAY MIGRATIONS
# ============================================================

FROM alpine:3.20 AS migrations

RUN apk add --no-cache \
    ca-certificates \
    curl \
    coreutils

WORKDIR /workspace

COPY migration-manifest.csv /workspace/migration-manifest.csv
COPY scripts/fetch-migrations.sh /workspace/scripts/fetch-migrations.sh

# Important:
# Run the script explicitly through "sh".
# This avoids executable-permission problems when files are
# uploaded through the GitHub web interface.
RUN sh /workspace/scripts/fetch-migrations.sh \
    /workspace/migration-manifest.csv \
    /workspace/migrations


# ============================================================
# STAGE 2: BUILD JAVA 21 APPLICATION WITH MAVEN
# ============================================================

FROM maven:3.9-eclipse-temurin-21 AS build

WORKDIR /build

# Copy Maven configuration first for dependency caching.
COPY pom.xml .

RUN mvn -q -DskipTests dependency:go-offline

# Copy Java source.
COPY src ./src

# Build the shaded/fat JAR.
RUN mvn -q clean package -DskipTests


# ============================================================
# STAGE 3: JAVA 21 RUNTIME
# ============================================================

FROM eclipse-temurin:21-jre

WORKDIR /app

# Copy runnable fat JAR.
COPY --from=build /build/target/app.jar /app/app.jar

# Copy the frozen and verified V1-V17 Flyway migrations.
COPY --from=migrations /workspace/migrations /app/migrations


# ============================================================
# RUNTIME CONFIGURATION
# ============================================================

# Governed Flyway migration directory inside container.
ENV MIGRATION_DIR=/app/migrations

# Runtime platform identifier.
ENV PLATFORM=RENDER

# Render normally supplies PORT dynamically.
# QualificationServer defaults to 8080 when PORT is absent.
EXPOSE 8080


# ============================================================
# START PHASE-0 QUALIFICATION SERVER
# ============================================================

ENTRYPOINT ["java", "-jar", "/app/app.jar"]
