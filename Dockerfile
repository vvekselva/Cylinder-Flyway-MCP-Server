# syntax=docker/dockerfile:1

FROM alpine:3.20 AS migrations
RUN apk add --no-cache ca-certificates curl coreutils
WORKDIR /workspace
COPY migration-manifest.csv /workspace/migration-manifest.csv
COPY scripts/fetch-migrations.sh /workspace/scripts/fetch-migrations.sh
RUN /workspace/scripts/fetch-migrations.sh /workspace/migration-manifest.csv /workspace/migrations

FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /build
COPY pom.xml .
RUN mvn -q -DskipTests dependency:go-offline
COPY src ./src
RUN mvn -q clean package -DskipTests

FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /build/target/app.jar /app/app.jar
COPY --from=migrations /workspace/migrations /app/migrations

ENV MIGRATION_DIR=/app/migrations
ENV PLATFORM=RENDER

EXPOSE 8080
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
