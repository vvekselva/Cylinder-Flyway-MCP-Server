package com.cylindermanagement.mcp;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import org.flywaydb.core.Flyway;
import org.flywaydb.core.api.MigrationInfo;
import org.flywaydb.core.api.MigrationInfoService;
import org.flywaydb.core.api.MigrationVersion;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.utility.DockerImageName;

import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.Statement;
import java.util.List;
import java.util.Locale;
import java.util.Objects;
import java.util.concurrent.Executors;
import java.util.concurrent.locks.ReentrantLock;
import java.util.stream.Stream;

/**
 * BL-008 Phase-1 Testcontainers migration validator.
 *
 * Safety invariants:
 *  - Writes are ONLY to an ephemeral PostgreSQL Testcontainer.
 *  - Supabase DB_URL / DB_USER / DB_PASSWORD are never read by this class.
 *  - DATABASE_WRITES must be exactly 1.
 *  - DB_WRITE_PARALLELISM must be exactly 1.
 *  - MIGRATION_BATCH_SIZE must be exactly 1.
 *  - One /phase1/migrate-next call can apply exactly one Flyway migration.
 *  - Genuine Flyway Java API migrate() is used.
 *  - No manual/raw SQL migration execution is used.
 *  - Database writes are serialized by a JVM lock.
 */
public final class Phase1TestcontainersServer {

    private static final String DEFAULT_IMAGE = "postgres:17.6";
    private static final int DEFAULT_PORT = 8081;

    private static final ReentrantLock DB_WRITE_LOCK = new ReentrantLock();

    private static volatile PostgreSQLContainer<?> postgres;
    private static volatile String lastAppliedVersion = "NONE";
    private static volatile String lastVerifiedVersion = "NONE";
    private static volatile String lastError = "NONE";

    private Phase1TestcontainersServer() {
    }

    public static void main(String[] args) throws Exception {
        int port = Integer.parseInt(envOrDefault("PORT", String.valueOf(DEFAULT_PORT)));

        HttpServer server =
                HttpServer.create(new InetSocketAddress("0.0.0.0", port), 0);

        server.createContext("/health", Phase1TestcontainersServer::health);
        server.createContext("/phase1/start", Phase1TestcontainersServer::start);
        server.createContext("/phase1/info", Phase1TestcontainersServer::info);
        server.createContext("/phase1/migrate-next", Phase1TestcontainersServer::migrateNext);
        server.createContext("/phase1/verify-last", Phase1TestcontainersServer::verifyLast);
        server.createContext("/phase1/stop", Phase1TestcontainersServer::stop);

        server.setExecutor(Executors.newCachedThreadPool());
        server.start();

        Runtime.getRuntime().addShutdownHook(
                new Thread(
                        () -> {
                            PostgreSQLContainer<?> current = postgres;
                            if (current != null) {
                                try {
                                    current.stop();
                                } catch (Throwable ignored) {
                                    // Best-effort shutdown.
                                }
                            }
                        },
                        "phase1-testcontainer-shutdown"));

        System.out.println(
                "BL-008 Phase-1 Testcontainers server started on port "
                        + port
                        + ". Writes are restricted to the ephemeral Testcontainer.");
    }

    // ============================================================
    // HEALTH
    // ============================================================

    private static void health(HttpExchange exchange) throws IOException {
        if (!"GET".equalsIgnoreCase(exchange.getRequestMethod())) {
            send(exchange, 405, "METHOD_NOT_ALLOWED\n");
            return;
        }

        Gate gate = evaluateGate();
        Path migrationDir = migrationDir();

        StringBuilder out = new StringBuilder();
        out.append("STATUS=UP\n");
        out.append("PHASE=TESTCONTAINERS_WRITE_VALIDATION\n");
        out.append("DATABASE_WRITES=").append(envOrDefault("DATABASE_WRITES", "UNSET")).append('\n');
        out.append("DB_WRITE_PARALLELISM=").append(envOrDefault("DB_WRITE_PARALLELISM", "UNSET")).append('\n');
        out.append("MIGRATION_BATCH_SIZE=").append(envOrDefault("MIGRATION_BATCH_SIZE", "UNSET")).append('\n');
        out.append("WRITE_GATE=").append(gate.pass ? "PASS" : "FAIL").append('\n');
        out.append("TESTCONTAINERS_POSTGRES_IMAGE=")
                .append(sanitize(envOrDefault("TESTCONTAINERS_POSTGRES_IMAGE", DEFAULT_IMAGE)))
                .append('\n');
        out.append("MIGRATION_DIR_PRESENT=")
                .append(Files.isDirectory(migrationDir) ? "PASS" : "FAIL")
                .append('\n');
        out.append("MIGRATION_SQL_FILES=").append(countSqlFiles(migrationDir)).append('\n');
        out.append("CONTAINER_RUNNING=").append(isContainerRunning() ? "YES" : "NO").append('\n');
        out.append("LAST_APPLIED_VERSION=").append(sanitize(lastAppliedVersion)).append('\n');
        out.append("LAST_VERIFIED_VERSION=").append(sanitize(lastVerifiedVersion)).append('\n');

        if (!gate.pass) {
            out.append("GATE_ERROR=").append(sanitize(gate.message)).append('\n');
        }

        if (!"NONE".equals(lastError)) {
            out.append("LAST_ERROR=").append(sanitize(lastError)).append('\n');
        }

        send(exchange, 200, out.toString());
    }

    // ============================================================
    // START TESTCONTAINER
    // ============================================================

    private static void start(HttpExchange exchange) throws IOException {
        if (!"POST".equalsIgnoreCase(exchange.getRequestMethod())) {
            send(exchange, 405, "METHOD_NOT_ALLOWED\n");
            return;
        }

        if (!authorize(exchange)) {
            return;
        }

        Gate gate = evaluateGate();
        if (!gate.pass) {
            send(exchange, 412, "START=REJECTED\nREASON=" + sanitize(gate.message) + "\n");
            return;
        }

        Path migrationDir = migrationDir();
        long sqlCount = countSqlFiles(migrationDir);

        if (!Files.isDirectory(migrationDir) || sqlCount <= 0) {
            send(
                    exchange,
                    412,
                    "START=REJECTED\n"
                            + "REASON=MIGRATION_DIR_INVALID_OR_EMPTY\n"
                            + "MIGRATION_SQL_FILES="
                            + sqlCount
                            + "\n");
            return;
        }

        if (!DB_WRITE_LOCK.tryLock()) {
            send(exchange, 409, "START=REJECTED\nREASON=DB_WRITE_LANE_BUSY\n");
            return;
        }

        try {
            if (isContainerRunning()) {
                send(
                        exchange,
                        200,
                        "START=ALREADY_RUNNING\n"
                                + containerSummary()
                                + infoSummary());
                return;
            }

            lastAppliedVersion = "NONE";
            lastVerifiedVersion = "NONE";
            lastError = "NONE";

            String image =
                    envOrDefault(
                            "TESTCONTAINERS_POSTGRES_IMAGE",
                            DEFAULT_IMAGE);

            PostgreSQLContainer<?> newContainer =
                    new PostgreSQLContainer<>(DockerImageName.parse(image))
                            .withDatabaseName("cylinder_bl008_test")
                            .withUsername("bl008")
                            .withPassword("bl008");

            newContainer.start();
            postgres = newContainer;

            MigrationInfoService info = baseFlyway().info();
            MigrationInfo firstPending = firstPending(info);

            StringBuilder out = new StringBuilder();
            out.append("START=PASS\n");
            out.append(containerSummary());
            out.append("MIGRATION_SQL_FILES=").append(sqlCount).append('\n');
            out.append("FIRST_PENDING_VERSION=").append(versionOf(firstPending)).append('\n');
            out.append("DATABASE_WRITES=TESTCONTAINER_ONLY\n");
            out.append("SUPABASE_WRITES=0\n");

            send(exchange, 200, out.toString());

        } catch (Throwable t) {
            lastError = safeMessage(t);
            stopContainerQuietly();
            send(
                    exchange,
                    500,
                    "START=FAIL\n"
                            + "ERROR="
                            + sanitize(lastError)
                            + "\n"
                            + "SUPABASE_WRITES=0\n");
        } finally {
            DB_WRITE_LOCK.unlock();
        }
    }

    // ============================================================
    // INFO
    // ============================================================

    private static void info(HttpExchange exchange) throws IOException {
        if (!"GET".equalsIgnoreCase(exchange.getRequestMethod())
                && !"POST".equalsIgnoreCase(exchange.getRequestMethod())) {
            send(exchange, 405, "METHOD_NOT_ALLOWED\n");
            return;
        }

        if (!authorize(exchange)) {
            return;
        }

        if (!isContainerRunning()) {
            send(exchange, 409, "INFO=FAIL\nREASON=TESTCONTAINER_NOT_RUNNING\n");
            return;
        }

        try {
            send(
                    exchange,
                    200,
                    "INFO=PASS\n"
                            + containerSummary()
                            + infoSummary());

        } catch (Throwable t) {
            lastError = safeMessage(t);
            send(
                    exchange,
                    500,
                    "INFO=FAIL\nERROR="
                            + sanitize(lastError)
                            + "\n");
        }
    }

    // ============================================================
    // MIGRATE EXACTLY ONE NEXT MIGRATION
    // ============================================================

    private static void migrateNext(HttpExchange exchange) throws IOException {
        if (!"POST".equalsIgnoreCase(exchange.getRequestMethod())) {
            send(exchange, 405, "METHOD_NOT_ALLOWED\n");
            return;
        }

        if (!authorize(exchange)) {
            return;
        }

        Gate gate = evaluateGate();
        if (!gate.pass) {
            send(exchange, 412, "MIGRATE_NEXT=REJECTED\nREASON=" + sanitize(gate.message) + "\n");
            return;
        }

        if (!isContainerRunning()) {
            send(exchange, 409, "MIGRATE_NEXT=REJECTED\nREASON=TESTCONTAINER_NOT_RUNNING\n");
            return;
        }

        if (!DB_WRITE_LOCK.tryLock()) {
            send(exchange, 409, "MIGRATE_NEXT=REJECTED\nREASON=DB_WRITE_LANE_BUSY\n");
            return;
        }

        try {
            Flyway beforeFlyway = baseFlyway();
            MigrationInfoService beforeInfo = beforeFlyway.info();
            MigrationInfo next = firstPending(beforeInfo);

            if (next == null || next.getVersion() == null) {
                send(
                        exchange,
                        200,
                        "MIGRATE_NEXT=NO_PENDING_MIGRATIONS\n"
                                + infoSummary());
                return;
            }

            String expectedVersion = next.getVersion().getVersion();
            long historyBefore = historySuccessfulCount();

            /*
             * Flyway target=next resolves to the first pending migration.
             * Since this Testcontainer is kept alive across calls, all
             * predecessor migrations are already applied. Therefore this
             * migrate() call can execute only the single next migration.
             */
            Flyway oneMigrationOnly =
                    Flyway.configure()
                            .dataSource(
                                    postgres.getJdbcUrl(),
                                    postgres.getUsername(),
                                    postgres.getPassword())
                            .locations("filesystem:" + migrationDir())
                            .schemas("public")
                            .defaultSchema("public")
                            .createSchemas(false)
                            .cleanDisabled(true)
                            .baselineOnMigrate(false)
                            .outOfOrder(false)
                            .validateOnMigrate(true)
                            .target(MigrationVersion.NEXT)
                            .load();

            oneMigrationOnly.migrate();

            long historyAfter = historySuccessfulCount();

            MigrationInfoService afterInfo = baseFlyway().info();
            MigrationInfo current = afterInfo.current();

            String currentVersion = versionOf(current);
            boolean exactIncrement = historyAfter == historyBefore + 1;
            boolean exactVersion = Objects.equals(expectedVersion, currentVersion);
            boolean historySuccess = historyContainsSuccessfulVersion(expectedVersion);

            if (!exactIncrement || !exactVersion || !historySuccess) {
                throw new IllegalStateException(
                        "Post-migration verification failed: expectedVersion="
                                + expectedVersion
                                + ", currentVersion="
                                + currentVersion
                                + ", historyBefore="
                                + historyBefore
                                + ", historyAfter="
                                + historyAfter
                                + ", historySuccess="
                                + historySuccess);
            }

            lastAppliedVersion = expectedVersion;
            lastVerifiedVersion = expectedVersion;
            lastError = "NONE";

            MigrationInfo nextAfter = firstPending(afterInfo);

            StringBuilder out = new StringBuilder();
            out.append("MIGRATE_NEXT=PASS\n");
            out.append("APPLIED_VERSION=").append(sanitize(expectedVersion)).append('\n');
            out.append("HISTORY_COUNT_BEFORE=").append(historyBefore).append('\n');
            out.append("HISTORY_COUNT_AFTER=").append(historyAfter).append('\n');
            out.append("CURRENT_VERSION=").append(sanitize(currentVersion)).append('\n');
            out.append("NEXT_PENDING_VERSION=").append(versionOf(nextAfter)).append('\n');
            out.append("MIGRATION_BATCH_SIZE=1\n");
            out.append("DB_WRITE_PARALLELISM=1\n");
            out.append("DATABASE_WRITES=TESTCONTAINER_ONLY\n");
            out.append("SUPABASE_WRITES=0\n");

            send(exchange, 200, out.toString());

        } catch (Throwable t) {
            lastError = safeMessage(t);

            StringBuilder out = new StringBuilder();
            out.append("MIGRATE_NEXT=FAIL\n");
            out.append("ERROR=").append(sanitize(lastError)).append('\n');
            out.append("CONTAINER_RETAINED_FOR_DIAGNOSIS=")
                    .append(isContainerRunning() ? "YES" : "NO")
                    .append('\n');
            out.append("SUPABASE_WRITES=0\n");

            send(exchange, 500, out.toString());

        } finally {
            DB_WRITE_LOCK.unlock();
        }
    }

    // ============================================================
    // VERIFY LAST
    // ============================================================

    private static void verifyLast(HttpExchange exchange) throws IOException {
        if (!"POST".equalsIgnoreCase(exchange.getRequestMethod())) {
            send(exchange, 405, "METHOD_NOT_ALLOWED\n");
            return;
        }

        if (!authorize(exchange)) {
            return;
        }

        if (!isContainerRunning()) {
            send(exchange, 409, "VERIFY_LAST=FAIL\nREASON=TESTCONTAINER_NOT_RUNNING\n");
            return;
        }

        if ("NONE".equals(lastAppliedVersion)) {
            send(exchange, 409, "VERIFY_LAST=FAIL\nREASON=NO_MIGRATION_APPLIED_IN_THIS_SESSION\n");
            return;
        }

        try {
            MigrationInfo current = baseFlyway().info().current();
            String currentVersion = versionOf(current);

            boolean currentMatches = Objects.equals(lastAppliedVersion, currentVersion);
            boolean historySuccess = historyContainsSuccessfulVersion(lastAppliedVersion);

            if (!currentMatches || !historySuccess) {
                send(
                        exchange,
                        409,
                        "VERIFY_LAST=FAIL\n"
                                + "EXPECTED_VERSION="
                                + sanitize(lastAppliedVersion)
                                + "\nCURRENT_VERSION="
                                + sanitize(currentVersion)
                                + "\nHISTORY_SUCCESS="
                                + historySuccess
                                + "\n");
                return;
            }

            lastVerifiedVersion = lastAppliedVersion;
            lastError = "NONE";

            send(
                    exchange,
                    200,
                    "VERIFY_LAST=PASS\n"
                            + "VERIFIED_VERSION="
                            + sanitize(lastVerifiedVersion)
                            + "\n"
                            + "SUCCESSFUL_HISTORY_COUNT="
                            + historySuccessfulCount()
                            + "\n"
                            + "SUPABASE_WRITES=0\n");

        } catch (Throwable t) {
            lastError = safeMessage(t);
            send(
                    exchange,
                    500,
                    "VERIFY_LAST=FAIL\nERROR="
                            + sanitize(lastError)
                            + "\n");
        }
    }

    // ============================================================
    // STOP
    // ============================================================

    private static void stop(HttpExchange exchange) throws IOException {
        if (!"POST".equalsIgnoreCase(exchange.getRequestMethod())) {
            send(exchange, 405, "METHOD_NOT_ALLOWED\n");
            return;
        }

        if (!authorize(exchange)) {
            return;
        }

        if (!DB_WRITE_LOCK.tryLock()) {
            send(exchange, 409, "STOP=REJECTED\nREASON=DB_WRITE_LANE_BUSY\n");
            return;
        }

        try {
            boolean wasRunning = isContainerRunning();
            stopContainerQuietly();

            send(
                    exchange,
                    200,
                    "STOP=PASS\n"
                            + "WAS_RUNNING="
                            + (wasRunning ? "YES" : "NO")
                            + "\n"
                            + "LAST_APPLIED_VERSION="
                            + sanitize(lastAppliedVersion)
                            + "\n"
                            + "LAST_VERIFIED_VERSION="
                            + sanitize(lastVerifiedVersion)
                            + "\n"
                            + "SUPABASE_WRITES=0\n");
        } finally {
            DB_WRITE_LOCK.unlock();
        }
    }

    // ============================================================
    // FLYWAY / DATABASE HELPERS
    // ============================================================

    private static Flyway baseFlyway() {
        requireContainer();

        return Flyway.configure()
                .dataSource(
                        postgres.getJdbcUrl(),
                        postgres.getUsername(),
                        postgres.getPassword())
                .locations("filesystem:" + migrationDir())
                .schemas("public")
                .defaultSchema("public")
                .createSchemas(false)
                .cleanDisabled(true)
                .baselineOnMigrate(false)
                .outOfOrder(false)
                .validateOnMigrate(true)
                .load();
    }

    private static MigrationInfo firstPending(MigrationInfoService info) {
        MigrationInfo[] pending = info.pending();

        if (pending == null || pending.length == 0) {
            return null;
        }

        return pending[0];
    }

    private static String versionOf(MigrationInfo migration) {
        if (migration == null || migration.getVersion() == null) {
            return "NONE";
        }

        return migration.getVersion().getVersion();
    }

    private static long historySuccessfulCount() throws Exception {
        requireContainer();

        try (Connection connection =
                     DriverManager.getConnection(
                             postgres.getJdbcUrl(),
                             postgres.getUsername(),
                             postgres.getPassword());
             Statement statement = connection.createStatement()) {

            try (ResultSet exists =
                         statement.executeQuery(
                                 "SELECT to_regclass('public.flyway_schema_history') IS NOT NULL")) {

                exists.next();

                if (!exists.getBoolean(1)) {
                    return 0;
                }
            }

            try (ResultSet count =
                         statement.executeQuery(
                                 "SELECT COUNT(*) "
                                         + "FROM public.flyway_schema_history "
                                         + "WHERE success = TRUE")) {

                count.next();
                return count.getLong(1);
            }
        }
    }

    private static boolean historyContainsSuccessfulVersion(String version) throws Exception {
        requireContainer();

        try (Connection connection =
                     DriverManager.getConnection(
                             postgres.getJdbcUrl(),
                             postgres.getUsername(),
                             postgres.getPassword());
             PreparedStatement statement =
                     connection.prepareStatement(
                             "SELECT COUNT(*) = 1 "
                                     + "FROM public.flyway_schema_history "
                                     + "WHERE version = ? AND success = TRUE")) {

            statement.setString(1, version);

            try (ResultSet rs = statement.executeQuery()) {
                rs.next();
                return rs.getBoolean(1);
            }
        }
    }

    private static String infoSummary() {
        try {
            MigrationInfoService info = baseFlyway().info();

            MigrationInfo current = info.current();
            MigrationInfo next = firstPending(info);
            MigrationInfo[] pending = info.pending();

            return "CURRENT_VERSION="
                    + versionOf(current)
                    + "\nFIRST_PENDING_VERSION="
                    + versionOf(next)
                    + "\nPENDING_COUNT="
                    + (pending == null ? 0 : pending.length)
                    + "\nSUCCESSFUL_HISTORY_COUNT="
                    + historySuccessfulCount()
                    + "\nLAST_APPLIED_VERSION="
                    + sanitize(lastAppliedVersion)
                    + "\nLAST_VERIFIED_VERSION="
                    + sanitize(lastVerifiedVersion)
                    + "\n";
        } catch (Throwable t) {
            return "INFO_ERROR=" + sanitize(safeMessage(t)) + "\n";
        }
    }

    private static String containerSummary() {
        PostgreSQLContainer<?> current = postgres;

        if (current == null || !current.isRunning()) {
            return "CONTAINER_RUNNING=NO\n";
        }

        return "CONTAINER_RUNNING=YES\n"
                + "POSTGRES_IMAGE="
                + sanitize(current.getDockerImageName())
                + "\n"
                + "DATABASE_NAME="
                + sanitize(current.getDatabaseName())
                + "\n";
    }

    private static void requireContainer() {
        if (!isContainerRunning()) {
            throw new IllegalStateException("Testcontainer is not running");
        }
    }

    private static boolean isContainerRunning() {
        PostgreSQLContainer<?> current = postgres;
        return current != null && current.isRunning();
    }

    private static void stopContainerQuietly() {
        PostgreSQLContainer<?> current = postgres;
        postgres = null;

        if (current != null) {
            try {
                current.stop();
            } catch (Throwable ignored) {
                // Best effort.
            }
        }
    }

    // ============================================================
    // GOVERNANCE GATES
    // ============================================================

    private static Gate evaluateGate() {
        String writes = envOrDefault("DATABASE_WRITES", "");
        String parallelism = envOrDefault("DB_WRITE_PARALLELISM", "");
        String batchSize = envOrDefault("MIGRATION_BATCH_SIZE", "");

        if (!"1".equals(writes)) {
            return new Gate(false, "DATABASE_WRITES_MUST_EQUAL_1");
        }

        if (!"1".equals(parallelism)) {
            return new Gate(false, "DB_WRITE_PARALLELISM_MUST_EQUAL_1");
        }

        if (!"1".equals(batchSize)) {
            return new Gate(false, "MIGRATION_BATCH_SIZE_MUST_EQUAL_1");
        }

        return new Gate(true, "PASS");
    }

    private record Gate(boolean pass, String message) {
    }

    // ============================================================
    // PATH / ENV / SECURITY
    // ============================================================

    private static Path migrationDir() {
        return Path.of(
                        envOrDefault(
                                "MIGRATION_DIR",
                                "/app/migrations"))
                .toAbsolutePath()
                .normalize();
    }

    private static long countSqlFiles(Path migrationDir) {
        if (!Files.isDirectory(migrationDir)) {
            return 0;
        }

        try (Stream<Path> paths = Files.walk(migrationDir)) {
            return paths
                    .filter(Files::isRegularFile)
                    .filter(
                            p -> p.getFileName()
                                    .toString()
                                    .toLowerCase(Locale.ROOT)
                                    .endsWith(".sql"))
                    .count();
        } catch (IOException e) {
            return 0;
        }
    }

    private static boolean authorize(HttpExchange exchange) throws IOException {
        String configured =
                envOrDefault(
                        "MCP_AUTH_TOKEN",
                        System.getenv("QUAL_TOKEN"));

        if (isBlank(configured)) {
            send(exchange, 503, "AUTH=FAIL\nREASON=MCP_AUTH_TOKEN_NOT_CONFIGURED\n");
            return false;
        }

        String actual =
                exchange
                        .getRequestHeaders()
                        .getFirst("Authorization");

        String expected = "Bearer " + configured;

        if (actual == null || !constantTimeEquals(actual, expected)) {
            send(exchange, 401, "AUTH=FAIL\nREASON=UNAUTHORIZED\n");
            return false;
        }

        return true;
    }

    private static boolean constantTimeEquals(String a, String b) {
        return MessageDigest.isEqual(
                a.getBytes(StandardCharsets.UTF_8),
                b.getBytes(StandardCharsets.UTF_8));
    }

    private static String envOrDefault(String name, String fallback) {
        String value = System.getenv(name);

        return isBlank(value)
                ? fallback
                : value;
    }

    private static boolean isBlank(String value) {
        return value == null || value.isBlank();
    }

    private static String safeMessage(Throwable t) {
        if (t == null) {
            return "UNKNOWN";
        }

        String text =
                Objects.toString(
                        t.getMessage(),
                        t.getClass().getSimpleName());

        return sanitize(text.length() > 500 ? text.substring(0, 500) : text);
    }

    private static String sanitize(String value) {
        if (value == null) {
            return "NONE";
        }

        return value
                .replace('\n', ' ')
                .replace('\r', ' ')
                .trim();
    }

    private static void send(
            HttpExchange exchange,
            int status,
            String body)
            throws IOException {

        byte[] bytes = body.getBytes(StandardCharsets.UTF_8);

        exchange.getResponseHeaders()
                .set("Content-Type", "text/plain; charset=utf-8");

        exchange.getResponseHeaders()
                .set("Cache-Control", "no-store");

        exchange.sendResponseHeaders(status, bytes.length);

        try (OutputStream out = exchange.getResponseBody()) {
            out.write(bytes);
        }
    }
}
