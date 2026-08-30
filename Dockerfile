# syntax=docker/dockerfile:1

# ============================================================
# STAGE 1: BUILD JAVA 21 APPLICATION AND RUNTIME DEPENDENCIES
# ============================================================

FROM maven:3.9-eclipse-temurin-21 AS build

WORKDIR /build

COPY pom.xml .
RUN mvn -q -DskipTests dependency:go-offline

COPY src ./src

# Keep dependencies as separate JARs. This preserves each library's
# package Implementation-Version used by the Phase-0 qualification gates.
RUN mvn -q clean package -DskipTests \
    && mvn -q dependency:copy-dependencies \
       -DincludeScope=runtime \
       -DoutputDirectory=target/lib


# ============================================================
# STAGE 2: JAVA 21 RUNTIME
# ============================================================

FROM eclipse-temurin:21-jre

WORKDIR /app

COPY --from=build /build/target/app.jar /app/app.jar
COPY --from=build /build/target/lib /app/lib

# Copy the complete governed Flyway SQL migration set.
COPY migrations /app/migrations

# Fail closed during image creation if migrations were not copied.
RUN test -d /app/migrations \
    && test "$(find /app/migrations -type f -name '*.sql' | wc -l)" -gt 0


# ============================================================
# RUNTIME CONFIGURATION
# ============================================================

ENV MIGRATION_DIR=/app/migrations
ENV PLATFORM=RENDER

EXPOSE 8080

# Run the application with its dependency JARs separately so Flyway and
# PostgreSQL retain their own package metadata. Phase-0 remains zero-write.
ENTRYPOINT ["java", "-cp", "/app/app.jar:/app/lib/*", "com.cylindermanagement.mcp.QualificationServer"]
