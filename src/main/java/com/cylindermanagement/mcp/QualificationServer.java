package com.cylindermanagement.mcp;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import org.flywaydb.core.Flyway;
import org.flywaydb.core.api.MigrationInfo;
import org.flywaydb.core.api.MigrationInfoService;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.Statement;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.List;
import java.util.Locale;
import java.util.Objects;
import java.util.Properties;
import java.util.concurrent.Executors;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.stream.Stream;

/**
 * Zero-write Phase-0 qualification service.
 *
 * This class intentionally exposes no migrate/clean/repair/baseline operation.
 * The only database activity is a read-only SELECT and Flyway.info().
 */
public final class QualificationServer {

    private static final String REQUIRED_FLYWAY_VERSION = "10.20.0";
    private static final String REQUIRED_POSTGRES_JDBC_VERSION = "42.7.2";

    private static final Pattern JDBC_ENDPOINT =
            Pattern.compile("^jdbc:postgresql://([^/:?#]+)(?::(\\d+))?/.*$");

    private QualificationServer() {
    }

    public static void main(String[] args) throws Exception {
        int port = Integer.parseInt(envOrDefault("PORT", "8080"));

        HttpServer server =
                HttpServer.create(new InetSocketAddress("0.0.0.0", port), 0);

        server.createContext("/health", QualificationServer::health);
        server.createContext("/qualify", QualificationServer::qualify);
        server.setExecutor(Executors.newCachedThreadPool());
        server.start();

        System.out.println(
                "Phase-0 qualification server started on port "
                        + port
                        + ". DATABASE_WRITES=0");
    }

    // ============================================================
    // HEALTH ENDPOINT
    // ============================================================

    /**
     * Safe health endpoint.
     *
     * This endpoint NEVER exposes actual secret values.
     */
    private static void health(HttpExchange exchange) throws IOException {
        if (!"GET".equalsIgnoreCase(exchange.getRequestMethod())) {
            send(exchange, 405, "METHOD_NOT_ALLOWED\n");
            return;
        }

        StringBuilder body = new StringBuilder();

        body.append("STATUS=UP\n");
        body.append("PHASE=ZERO_WRITE\n");
        body.append("QUAL_TOKEN_PRESENT=")
                .append(isBlank(System.getenv("QUAL_TOKEN")) ? "NO" : "YES")
                .append('\n');
        body.append("DB_PASSWORD_PRESENT=")
                .append(isBlank(System.getenv("DB_PASSWORD")) ? "NO" : "YES")
                .append('\n');
        body.append("DB_URL_PRESENT=")
                .append(isBlank(System.getenv("DB_URL")) ? "NO" : "YES")
                .append('\n');
        body.append("DB_USER_PRESENT=")
                .append(isBlank(System.getenv("DB_USER")) ? "NO" : "YES")
                .append('\n');
        body.append("MIGRATION_DIR_PRESENT=")
                .append(isBlank(System.getenv("MIGRATION_DIR")) ? "NO" : "YES")
                .append('\n');
        body.append("PLATFORM_PRESENT=")
                .append(isBlank(System.getenv("PLATFORM")) ? "NO" : "YES")
                .append('\n');
        body.append("DATABASE_WRITES=0\n");

        send(exchange, 200, body.toString());
    }

    // ============================================================
    // QUALIFICATION ENDPOINT
    // ============================================================

    private static void qualify(HttpExchange exchange) throws IOException {
        if (!"POST".equalsIgnoreCase(exchange.getRequestMethod())) {
            send(exchange, 405, "METHOD_NOT_ALLOWED\n");
            return;
        }

        String configuredToken = System.getenv("QUAL_TOKEN");

        if (isBlank(configuredToken)) {
            send(
                    exchange,
                    503,
                    "QUALIFICATION_ENDPOINT_NOT_CONFIGURED\n"
                            + "DATABASE_WRITES=0\n");
            return;
        }

        String auth = exchange.getRequestHeaders().getFirst("Authorization");
        String expected = "Bearer " + configuredToken;

        if (auth == null || !constantTimeEquals(auth, expected)) {
            send(
                    exchange,
                    401,
                    "UNAUTHORIZED\n"
                            + "DATABASE_WRITES=0\n");
            return;
        }

        Report report = runQualification();
        send(exchange, 200, report.render());
    }

    // ============================================================
    // PHASE-0 QUALIFICATION
    // ============================================================

    private static Report runQualification() {
        Report r = new Report();

        r.platform = envOrDefault("PLATFORM", "RENDER");
        r.javaVersion = System.getProperty("java.version", "UNKNOWN");
        r.java21 = Runtime.version().feature() == 21;

        // --------------------------------------------------------
        // Flyway version
        // --------------------------------------------------------
        try {
            r.flywayVersion =
                    artifactVersion(
                            "org.flywaydb",
                            "flyway-core",
                            Flyway.class);

            r.flyway10200 =
                    versionMatches(
                            r.flywayVersion,
                            REQUIRED_FLYWAY_VERSION);

        } catch (Throwable t) {
            r.flywayVersion = "UNAVAILABLE";
            r.flyway10200 = false;
            r.errors.add("FLYWAY_VERSION=" + safeMessage(t));
        }

        // --------------------------------------------------------
        // PostgreSQL JDBC version
        // --------------------------------------------------------
        try {
            Class<?> pgDriver = Class.forName("org.postgresql.Driver");

            r.postgresJdbcVersion =
                    artifactVersion(
                            "org.postgresql",
                            "postgresql",
                            pgDriver);

            r.postgresJdbc4272 =
                    versionMatches(
                            r.postgresJdbcVersion,
                            REQUIRED_POSTGRES_JDBC_VERSION);

        } catch (Throwable t) {
            r.postgresJdbcVersion = "UNAVAILABLE";
            r.postgresJdbc4272 = false;
            r.errors.add("POSTGRESQL_JDBC_VERSION=" + safeMessage(t));
        }

        // --------------------------------------------------------
        // Environment
        // --------------------------------------------------------
        String dbUrl = System.getenv("DB_URL");
        String dbUser = System.getenv("DB_USER");
        String dbPassword = System.getenv("DB_PASSWORD");
        String migrationDir = System.getenv("MIGRATION_DIR");

        r.secrets =
                allPresent(
                        "QUAL_TOKEN",
                        "DB_URL",
                        "DB_USER",
                        "DB_PASSWORD",
                        "MIGRATION_DIR");

        // --------------------------------------------------------
        // Parse PostgreSQL endpoint
        // --------------------------------------------------------
        Endpoint endpoint = parseEndpoint(dbUrl);

        if (endpoint == null) {
            r.errors.add("DB_ENDPOINT=Unable to parse DB_URL");
        } else {
            // DNS
            try {
                InetAddress[] addresses =
                        InetAddress.getAllByName(endpoint.host());

                r.dns = addresses.length > 0;

                if (r.dns) {
                    r.resolvedIps =
                            Arrays.stream(addresses)
                                    .map(InetAddress::getHostAddress)
                                    .distinct()
                                    .sorted()
                                    .toList();
                }

            } catch (Throwable t) {
                r.dns = false;
                r.errors.add("DNS=" + safeMessage(t));
            }

            // TCP
            if (r.dns) {
                try (Socket socket = new Socket()) {
                    socket.connect(
                            new InetSocketAddress(
                                    endpoint.host(),
                                    endpoint.port()),
                            7000);

                    r.tcp5432 = socket.isConnected();

                } catch (Throwable t) {
                    r.tcp5432 = false;
                    r.errors.add("TCP_5432=" + safeMessage(t));
                }
            }
        }

        // --------------------------------------------------------
        // Migration directory qualification
        // --------------------------------------------------------
        if (!isBlank(migrationDir)) {
            Path dir = Path.of(migrationDir);

            r.migrationDirPresent = Files.isDirectory(dir);

            if (r.migrationDirPresent) {
                try (Stream<Path> paths = Files.walk(dir)) {
                    r.migrationSqlFiles =
                            paths.filter(Files::isRegularFile)
                                    .filter(
                                            p -> p.getFileName()
                                                    .toString()
                                                    .toLowerCase(Locale.ROOT)
                                                    .endsWith(".sql"))
                                    .count();

                } catch (Throwable t) {
                    r.migrationDirPresent = false;
                    r.errors.add("MIGRATION_DIR=" + safeMessage(t));
                }
            }
        }

        // --------------------------------------------------------
        // JDBC qualification
        // --------------------------------------------------------
        boolean jdbcGate =
                r.java21
                        && r.postgresJdbc4272
                        && r.secrets
                        && r.dns
                        && r.tcp5432;

        if (jdbcGate) {
            try (Connection connection =
                         DriverManager.getConnection(
                                 dbUrl,
                                 dbUser,
                                 dbPassword)) {

                connection.setReadOnly(true);

                try (Statement statement = connection.createStatement();
                     ResultSet rs =
                             statement.executeQuery(
                                     "SELECT current_database(), "
                                             + "current_user, "
                                             + "current_setting('server_version')")) {

                    if (rs.next()) {
                        r.jdbcAuth = true;
                        r.database = rs.getString(1);

                        // Do not expose current_user.
                        r.serverVersion = rs.getString(3);
                    }
                }

            } catch (Throwable t) {
                r.jdbcAuth = false;
                r.errors.add("JDBC_AUTH=" + safeMessage(t));
            }
        }

        // --------------------------------------------------------
        // Flyway INFO qualification
        // --------------------------------------------------------
        boolean flywayGate =
                r.jdbcAuth
                        && r.flyway10200
                        && r.migrationDirPresent
                        && r.migrationSqlFiles > 0;

        if (flywayGate) {
            try {
                Flyway flyway =
                        Flyway.configure()
                                .dataSource(
                                        dbUrl,
                                        dbUser,
                                        dbPassword)
                                .locations(
                                        "filesystem:" + migrationDir)
                                .schemas("public")
                                .defaultSchema("public")
                                .createSchemas(false)
                                .cleanDisabled(true)
                                .baselineOnMigrate(false)
                                .outOfOrder(false)
                                .load();

                /*
                 * ZERO-WRITE:
                 *
                 * Only Flyway.info() is executed.
                 *
                 * No migrate()
                 * No clean()
                 * No repair()
                 * No baseline()
                 */
                MigrationInfoService info = flyway.info();

                MigrationInfo[] all = info.all();
                r.flywayInfo = true;

                if (all != null) {
                    List<MigrationInfo> ordered =
                            new ArrayList<>(
                                    Arrays.asList(all));

                    ordered.sort(
                            Comparator.comparing(
                                    m -> m.getVersion() == null
                                            ? ""
                                            : m.getVersion().getVersion()));

                    for (MigrationInfo migration : ordered) {
                        r.migrations.add(
                                formatMigration(migration));
                    }
                }

                MigrationInfo[] pending = info.pending();

                if (pending != null
                        && pending.length > 0
                        && pending[0].getVersion() != null) {

                    r.firstPendingVersion =
                            pending[0]
                                    .getVersion()
                                    .getVersion();
                } else {
                    r.firstPendingVersion = "NONE";
                }

            } catch (Throwable t) {
                r.flywayInfo = false;
                r.errors.add("FLYWAY_INFO=" + safeMessage(t));
            }
        }

        // --------------------------------------------------------
        // Final Phase-0 qualification result
        // --------------------------------------------------------
        r.overallSuitable =
                r.java21
                        && r.flyway10200
                        && r.postgresJdbc4272
                        && r.dns
                        && r.tcp5432
                        && r.secrets
                        && r.migrationDirPresent
                        && r.migrationSqlFiles > 0
                        && r.jdbcAuth
                        && r.flywayInfo;

        return r;
    }

    // ============================================================
    // MIGRATION FORMAT
    // ============================================================

    private static String formatMigration(MigrationInfo m) {
        String version =
                m.getVersion() == null
                        ? "NONE"
                        : m.getVersion().getVersion();

        String checksum =
                m.getChecksum() == null
                        ? "NONE"
                        : String.valueOf(m.getChecksum());

        return "MIGRATION version="
                + sanitizeLine(version)
                + " description="
                + sanitizeLine(m.getDescription())
                + " script="
                + sanitizeLine(m.getScript())
                + " checksum="
                + sanitizeLine(checksum)
                + " state="
                + sanitizeLine(String.valueOf(m.getState()));
    }

    // ============================================================
    // JDBC URL PARSER
    // ============================================================

    private static Endpoint parseEndpoint(String jdbcUrl) {
        if (isBlank(jdbcUrl)) {
            return null;
        }

        Matcher matcher = JDBC_ENDPOINT.matcher(jdbcUrl);

        if (!matcher.matches()) {
            return null;
        }

        int port =
                matcher.group(2) == null
                        ? 5432
                        : Integer.parseInt(matcher.group(2));

        return new Endpoint(
                matcher.group(1),
                port);
    }

    // ============================================================
    // ENVIRONMENT / VERSION HELPERS
    // ============================================================

    private static boolean allPresent(String... names) {
        for (String name : names) {
            if (isBlank(System.getenv(name))) {
                return false;
            }
        }

        return true;
    }

    /**
     * Reads an artifact version from Maven pom.properties.
     *
     * This is more reliable than Package.getImplementationVersion()
     * for libraries such as Flyway. It falls back to package metadata
     * and then the dependency JAR filename.
     */
    private static String artifactVersion(
            String groupId,
            String artifactId,
            Class<?> type) {

        String resource =
                "/META-INF/maven/"
                        + groupId
                        + "/"
                        + artifactId
                        + "/pom.properties";

        try (InputStream in =
                     type.getResourceAsStream(resource)) {

            if (in != null) {
                Properties properties =
                        new Properties();

                properties.load(in);

                String version =
                        properties.getProperty("version");

                if (!isBlank(version)) {
                    return version.trim();
                }
            }

        } catch (IOException ignored) {
            // Continue to safe fallbacks.
        }

        String packageVersion =
                implementationVersion(type);

        if (!"UNKNOWN".equals(packageVersion)) {
            return packageVersion;
        }

        try {
            String location =
                    String.valueOf(
                            type.getProtectionDomain()
                                    .getCodeSource()
                                    .getLocation());

            Pattern jarPattern =
                    Pattern.compile(
                            Pattern.quote(artifactId)
                                    + "-([0-9][A-Za-z0-9._-]*)\\.jar(?:!/)?.*$");

            Matcher matcher =
                    jarPattern.matcher(location);

            if (matcher.find()) {
                return matcher.group(1);
            }

        } catch (Throwable ignored) {
            // Fail closed below.
        }

        return "UNKNOWN";
    }

    private static String implementationVersion(Class<?> type) {
        String version =
                type.getPackage() == null
                        ? null
                        : type.getPackage()
                                .getImplementationVersion();

        return isBlank(version)
                ? "UNKNOWN"
                : version;
    }

    private static boolean versionMatches(
            String actual,
            String expected) {

        return actual != null
                && (actual.equals(expected)
                || actual.startsWith(expected + "."));
    }

    private static String envOrDefault(
            String name,
            String fallback) {

        String value = System.getenv(name);

        return isBlank(value)
                ? fallback
                : value;
    }

    private static boolean isBlank(String value) {
        return value == null || value.isBlank();
    }

    // ============================================================
    // SECURITY HELPERS
    // ============================================================

    private static boolean constantTimeEquals(
            String a,
            String b) {

        return MessageDigest.isEqual(
                a.getBytes(StandardCharsets.UTF_8),
                b.getBytes(StandardCharsets.UTF_8));
    }

    /**
     * Removes configured secrets from exception messages.
     */
    private static String safeMessage(Throwable t) {
        String text =
                t == null
                        ? "UNKNOWN"
                        : Objects.toString(
                                t.getMessage(),
                                t.getClass()
                                        .getSimpleName());

        for (String key :
                List.of(
                        "DB_URL",
                        "DB_USER",
                        "DB_PASSWORD",
                        "QUAL_TOKEN")) {

            String secret =
                    System.getenv(key);

            if (!isBlank(secret)) {
                text =
                        text.replace(
                                secret,
                                "[REDACTED]");
            }
        }

        text = sanitizeLine(text);

        return text.length() > 300
                ? text.substring(0, 300)
                : text;
    }

    private static String sanitizeLine(String value) {
        if (value == null) {
            return "NONE";
        }

        return value
                .replace('\n', ' ')
                .replace('\r', ' ')
                .trim();
    }

    // ============================================================
    // HTTP RESPONSE
    // ============================================================

    private static void send(
            HttpExchange exchange,
            int status,
            String body)
            throws IOException {

        byte[] bytes =
                body.getBytes(StandardCharsets.UTF_8);

        exchange.getResponseHeaders()
                .set(
                        "Content-Type",
                        "text/plain; charset=utf-8");

        exchange.getResponseHeaders()
                .set(
                        "Cache-Control",
                        "no-store");

        exchange.sendResponseHeaders(
                status,
                bytes.length);

        try (OutputStream out =
                     exchange.getResponseBody()) {

            out.write(bytes);
        }
    }

    // ============================================================
    // RECORDS
    // ============================================================

    private record Endpoint(
            String host,
            int port) {
    }

    // ============================================================
    // REPORT
    // ============================================================

    private static final class Report {

        String platform = "RENDER";

        String javaVersion = "UNKNOWN";
        boolean java21;

        String flywayVersion = "UNKNOWN";
        boolean flyway10200;

        String postgresJdbcVersion = "UNKNOWN";
        boolean postgresJdbc4272;

        boolean dns;
        List<String> resolvedIps = List.of();
        boolean tcp5432;

        boolean secrets;

        boolean migrationDirPresent;
        long migrationSqlFiles;

        boolean jdbcAuth;
        String database = "UNKNOWN";
        String serverVersion = "UNKNOWN";

        boolean flywayInfo;
        String firstPendingVersion = "NONE";

        boolean overallSuitable;

        final List<String> migrations =
                new ArrayList<>();

        final List<String> errors =
                new ArrayList<>();

        String render() {
            StringBuilder out =
                    new StringBuilder();

            out.append("PLATFORM=")
                    .append(sanitizeLine(platform))
                    .append('\n');

            out.append("JAVA_VERSION=")
                    .append(sanitizeLine(javaVersion))
                    .append('\n');

            out.append("JAVA_21=")
                    .append(pass(java21))
                    .append('\n');

            out.append("FLYWAY_VERSION=")
                    .append(sanitizeLine(flywayVersion))
                    .append('\n');

            out.append("FLYWAY_10_20_0=")
                    .append(pass(flyway10200))
                    .append('\n');

            out.append("POSTGRESQL_JDBC_VERSION=")
                    .append(sanitizeLine(postgresJdbcVersion))
                    .append('\n');

            out.append("POSTGRESQL_JDBC_42_7_2=")
                    .append(pass(postgresJdbc4272))
                    .append('\n');

            out.append("DNS=")
                    .append(pass(dns))
                    .append('\n');

            if (!resolvedIps.isEmpty()) {
                out.append("RESOLVED_IPS=")
                        .append(String.join(",", resolvedIps))
                        .append('\n');
            }

            out.append("TCP_5432=")
                    .append(pass(tcp5432))
                    .append('\n');

            out.append("SECRETS=")
                    .append(pass(secrets))
                    .append('\n');

            out.append("MIGRATION_DIR_PRESENT=")
                    .append(pass(migrationDirPresent))
                    .append('\n');

            out.append("MIGRATION_SQL_FILES=")
                    .append(migrationSqlFiles)
                    .append('\n');

            out.append("JDBC_AUTH=")
                    .append(pass(jdbcAuth))
                    .append('\n');

            if (jdbcAuth) {
                out.append("DATABASE=")
                        .append(sanitizeLine(database))
                        .append('\n');

                out.append("SERVER_VERSION=")
                        .append(sanitizeLine(serverVersion))
                        .append('\n');
            }

            out.append("FLYWAY_INFO=")
                    .append(pass(flywayInfo))
                    .append('\n');

            for (String migration : migrations) {
                out.append(migration)
                        .append('\n');
            }

            out.append("FIRST_PENDING_VERSION=")
                    .append(sanitizeLine(firstPendingVersion))
                    .append('\n');

            for (String error : errors) {
                out.append("ERROR_")
                        .append(error)
                        .append('\n');
            }

            out.append("DATABASE_WRITES=0\n");

            out.append("OVERALL=")
                    .append(
                            overallSuitable
                                    ? "SUITABLE_FOR_FLYWAY_MCP"
                                    : "NOT_SUITABLE_FOR_FLYWAY_MCP")
                    .append('\n');

            return out.toString();
        }

        private static String pass(boolean value) {
            return value ? "PASS" : "FAIL";
        }
    }
}
