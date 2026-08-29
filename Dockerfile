# syntax=docker/dockerfile:1

# ============================================================
# STAGE 1: BUILD JAVA 21 APPLICATION WITH MAVEN
# ============================================================

FROM maven:3.9-eclipse-temurin-21 AS build

WORKDIR /build

# Copy Maven configuration first for dependency caching
COPY pom.xml .

RUN mvn -q -DskipTests dependency:go-offline

# Copy Java source
COPY src ./src

# Build the shaded / fat JAR
RUN mvn -q clean package -DskipTests


# ============================================================
# STAGE 2: JAVA 21 RUNTIME
# ============================================================

FROM eclipse-temurin:21-jre

WORKDIR /app

# Copy runnable application
COPY --from=build /build/target/app.jar /app/app.jar

# Copy the complete governed Flyway SQL migration set
# Expected: 168 SQL files, V1-V170 with V116 and V157 absent
COPY migrations /app/migrations


# ============================================================
# RUNTIME CONFIGURATION
# ============================================================

ENV MIGRATION_DIR=/app/migrations
ENV PLATFORM=RENDER

# Render supplies PORT dynamically.
# QualificationServer defaults to 8080 when PORT is absent.
EXPOSE 8080


# ============================================================
# START ZERO-WRITE PHASE-0 QUALIFICATION SERVER
# ============================================================

ENTRYPOINT ["java", "-jar", "/app/app.jar"]
