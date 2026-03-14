package ci.codegen;

import cn.iocoder.yudao.framework.mybatis.core.type.EncryptTypeHandler;
import cn.iocoder.yudao.module.infra.controller.admin.codegen.vo.CodegenCreateListReqVO;
import cn.iocoder.yudao.module.infra.dal.dataobject.codegen.CodegenTableDO;
import cn.iocoder.yudao.module.infra.dal.mysql.codegen.CodegenTableMapper;
import cn.iocoder.yudao.module.infra.enums.codegen.CodegenFrontTypeEnum;
import cn.iocoder.yudao.module.infra.enums.codegen.CodegenSceneEnum;
import cn.iocoder.yudao.module.infra.enums.codegen.CodegenTemplateTypeEnum;
import cn.iocoder.yudao.module.infra.framework.codegen.config.CodegenProperties;
import cn.iocoder.yudao.module.infra.service.codegen.CodegenService;
import cn.iocoder.yudao.server.YudaoServerApplication;
import jakarta.annotation.Resource;
import org.junit.jupiter.api.Test;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.context.ActiveProfiles;

import javax.sql.DataSource;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.*;
import java.util.*;
import java.util.stream.Collectors;

import static org.junit.jupiter.api.Assertions.*;

@SpringBootTest(
        classes = YudaoServerApplication.class,
        webEnvironment = SpringBootTest.WebEnvironment.MOCK
)
@ActiveProfiles({"local", "ci-codegen"})
public class CiCodegenIT {

    @Resource
    private CodegenService codegenService;

    @Resource
    private CodegenTableMapper codegenTableMapper;

    @Resource
    private CodegenProperties codegenProperties;

    @Resource
    private DataSource dataSource;

    @Test
    public void importAndGenerate() throws Exception {
        String dbUrl = mustEnv("DB_URL");
        String dbUser = mustEnv("DB_USER");
        String dbPwd = mustEnv("DB_PWD");
        String outDir = mustEnv("CODEGEN_OUTPUT_DIR");
        String moduleName = mustEnv("CODEGEN_MODULE_NAME");
        String tablePrefix = System.getenv().getOrDefault("CODEGEN_TABLE_PREFIX", moduleName + "_");

        try (Connection conn = dataSource.getConnection()) {
            String schema = conn.getCatalog();

            ensureTableExists(conn, schema, "infra_codegen_table");
            ensureTableExists(conn, schema, "infra_codegen_column");
            ensureTableExists(conn, schema, "infra_data_source_config");

            List<String> tableNames = listBusinessTables(conn, schema, tablePrefix);
            if (tableNames.isEmpty()) {
                throw new IllegalStateException("No business tables found for prefix: " + tablePrefix);
            }

            purgeExistingCodegen(conn, tablePrefix);
            Long dataSourceConfigId = resolveOrCreateDataSourceConfigId(conn, schema, dbUrl, dbUser, dbPwd);

            CodegenCreateListReqVO reqVO = new CodegenCreateListReqVO();
            reqVO.setDataSourceConfigId(dataSourceConfigId);
            reqVO.setTableNames(tableNames);

            List<Long> ids = codegenService.createCodegenList("ci-codegen", reqVO);
            assertEquals(tableNames.size(), ids.size(), "Imported table count mismatch");

            Path outBase = Path.of(outDir);

            for (Long tableId : ids) {
                CodegenTableDO table = codegenTableMapper.selectById(tableId);
                assertNotNull(table, "Imported codegen table missing: " + tableId);

                normalizeTable(table, moduleName, tablePrefix);
                codegenTableMapper.updateById(table);

                Map<String, String> files = codegenService.generationCodes(tableId);
                assertFalse(files.isEmpty(), "Generated files should not be empty for tableId=" + tableId);

                assertNoUnresolvedTemplateVars(table.getTableName(), files);
                writeAll(outBase, files);
            }
        }

        System.out.println("codegenProperties.voType = " + codegenProperties.getVoType());
        System.out.println("codegenProperties.frontType = " + codegenProperties.getFrontType());
    }

    private static void normalizeTable(CodegenTableDO table, String moduleName, String tablePrefix) {
        table.setScene(CodegenSceneEnum.ADMIN.getScene());

        if (table.getFrontType() == null) {
            table.setFrontType(CodegenFrontTypeEnum.VUE3_ELEMENT_PLUS.getType());
        }
        if (table.getTemplateType() == null) {
            table.setTemplateType(CodegenTemplateTypeEnum.ONE.getType());
        }
        if (isBlank(table.getModuleName())) {
            table.setModuleName(moduleName);
        }
        if (isBlank(table.getBusinessName()) && !isBlank(table.getTableName())) {
            table.setBusinessName(stripPrefix(table.getTableName(), tablePrefix));
        }
        if (isBlank(table.getClassName()) && !isBlank(table.getTableName())) {
            table.setClassName(toClassName(table.getTableName()));
        }
        if (isBlank(table.getAuthor())) {
            table.setAuthor("ci-codegen");
        }
        if (table.getParentMenuId() == null) {
            table.setParentMenuId(0L);
        }
    }

    private static void assertNoUnresolvedTemplateVars(String tableName, Map<String, String> files) {
            List<String> suspiciousTokens = List.of(
                    "${saveReqVOClass}",
                    "${saveReqVOVar}",
                    "${updateReqVOClass}",
                    "${updateReqVOVar}",
                    "${respVOClass}",
                    "${table.classComment}",
                    "${classComment}",
                    "${requestClass}",
                    "${responseClass}"
            );
        
            List<String> backendExt = List.of(".java", ".xml", ".sql", ".yml", ".yaml", ".properties", ".kt");
            List<String> badFiles = new ArrayList<>();
            String firstSnippet = null;
            String firstFile = null;
        
            for (Map.Entry<String, String> e : files.entrySet()) {
                String path = e.getKey();
                String content = e.getValue();
                if (content == null) {
                    continue;
                }
        
                boolean targetedHit = suspiciousTokens.stream().anyMatch(content::contains);
                boolean backendBroadHit = backendExt.stream().anyMatch(path::endsWith) && content.contains("${");
        
                if (!targetedHit && !backendBroadHit) {
                    continue;
                }
        
                badFiles.add(path);
                if (firstSnippet == null) {
                    firstFile = path;
                    firstSnippet = content.substring(0, Math.min(content.length(), 1200));
                }
            }
        
            if (!badFiles.isEmpty()) {
                throw new AssertionError(
                        "Unresolved template vars found, table=" + tableName
                                + ", files=" + badFiles
                                + ", firstFile=" + firstFile
                                + "\n" + firstSnippet
                );
            }
        }


    private static List<String> listBusinessTables(Connection conn, String schema, String tablePrefix) throws SQLException {
        String sql = """
                SELECT table_name
                FROM information_schema.tables
                WHERE table_schema = ?
                  AND table_type = 'BASE TABLE'
                  AND table_name LIKE ?
                ORDER BY table_name
                """;
        List<String> list = new ArrayList<>();
        try (PreparedStatement ps = conn.prepareStatement(sql)) {
            ps.setString(1, schema);
            ps.setString(2, tablePrefix + "%");
            try (ResultSet rs = ps.executeQuery()) {
                while (rs.next()) {
                    list.add(rs.getString(1));
                }
            }
        }
        return list;
    }

    private static void purgeExistingCodegen(Connection conn, String tablePrefix) throws SQLException {
        List<Long> ids = new ArrayList<>();

        try (PreparedStatement ps = conn.prepareStatement(
                "SELECT id FROM infra_codegen_table WHERE table_name LIKE ?")) {
            ps.setString(1, tablePrefix + "%");
            try (ResultSet rs = ps.executeQuery()) {
                while (rs.next()) {
                    ids.add(rs.getLong(1));
                }
            }
        }

        if (!ids.isEmpty()) {
            String inSql = String.join(",", Collections.nCopies(ids.size(), "?"));
            try (PreparedStatement ps = conn.prepareStatement(
                    "DELETE FROM infra_codegen_column WHERE table_id IN (" + inSql + ")")) {
                for (int i = 0; i < ids.size(); i++) {
                    ps.setLong(i + 1, ids.get(i));
                }
                ps.executeUpdate();
            }
        }

        try (PreparedStatement ps = conn.prepareStatement(
                "DELETE FROM infra_codegen_table WHERE table_name LIKE ?")) {
            ps.setString(1, tablePrefix + "%");
            ps.executeUpdate();
        }
    }

    private static Long resolveOrCreateDataSourceConfigId(Connection conn, String schema,
                                                          String jdbcUrl, String username, String password) throws SQLException {
        try (PreparedStatement ps = conn.prepareStatement(
                "SELECT id FROM infra_data_source_config ORDER BY id LIMIT 1");
             ResultSet rs = ps.executeQuery()) {
            if (rs.next()) {
                return rs.getLong(1);
            }
        }

        Set<String> cols = loadTableColumns(conn, schema, "infra_data_source_config");
        LinkedHashMap<String, Object> values = new LinkedHashMap<>();
        Timestamp now = new Timestamp(System.currentTimeMillis());

        putIfHas(cols, values, "name", "ci-codegen");
        putIfHas(cols, values, "remark", "auto created for codegen ci");
        putIfHas(cols, values, "url", jdbcUrl);
        putIfHas(cols, values, "jdbc_url", jdbcUrl);
        putIfHas(cols, values, "username", username);
        putIfHas(cols, values, "password", EncryptTypeHandler.encrypt(password));
        putIfHas(cols, values, "db_type", "MySQL");
        putIfHas(cols, values, "database_type", "MySQL");
        putIfHas(cols, values, "status", 0);
        putIfHas(cols, values, "deleted", 0);
        putIfHas(cols, values, "tenant_id", 0L);
        putIfHas(cols, values, "creator", "ci");
        putIfHas(cols, values, "updater", "ci");
        putIfHas(cols, values, "create_time", now);
        putIfHas(cols, values, "update_time", now);

        if (values.isEmpty()) {
            throw new IllegalStateException("No insertable columns found for infra_data_source_config");
        }

        String columns = String.join(", ", values.keySet());
        String placeholders = String.join(", ", Collections.nCopies(values.size(), "?"));
        String sql = "INSERT INTO infra_data_source_config (" + columns + ") VALUES (" + placeholders + ")";

        try (PreparedStatement ps = conn.prepareStatement(sql, Statement.RETURN_GENERATED_KEYS)) {
            int idx = 1;
            for (Object v : values.values()) {
                ps.setObject(idx++, v);
            }
            ps.executeUpdate();
            try (ResultSet rs = ps.getGeneratedKeys()) {
                if (rs.next()) {
                    return rs.getLong(1);
                }
            }
        }

        try (PreparedStatement ps = conn.prepareStatement(
                "SELECT id FROM infra_data_source_config WHERE name = ? ORDER BY id LIMIT 1")) {
            ps.setString(1, "ci-codegen");
            try (ResultSet rs = ps.executeQuery()) {
                if (rs.next()) {
                    return rs.getLong(1);
                }
            }
        }

        throw new IllegalStateException("Failed to create infra_data_source_config row");
    }

    private static void ensureTableExists(Connection conn, String schema, String tableName) throws SQLException {
        try (PreparedStatement ps = conn.prepareStatement("""
                SELECT COUNT(*)
                FROM information_schema.tables
                WHERE table_schema = ? AND table_name = ?
                """)) {
            ps.setString(1, schema);
            ps.setString(2, tableName);
            try (ResultSet rs = ps.executeQuery()) {
                rs.next();
                if (rs.getInt(1) <= 0) {
                    throw new IllegalStateException("Missing table: " + tableName + " in schema " + schema);
                }
            }
        }
    }

    private static Set<String> loadTableColumns(Connection conn, String schema, String tableName) throws SQLException {
        Set<String> cols = new LinkedHashSet<>();
        try (PreparedStatement ps = conn.prepareStatement("""
                SELECT column_name
                FROM information_schema.columns
                WHERE table_schema = ? AND table_name = ?
                ORDER BY ordinal_position
                """)) {
            ps.setString(1, schema);
            ps.setString(2, tableName);
            try (ResultSet rs = ps.executeQuery()) {
                while (rs.next()) {
                    cols.add(rs.getString(1).toLowerCase(Locale.ROOT));
                }
            }
        }
        return cols;
    }

    private static void putIfHas(Set<String> existingCols, Map<String, Object> values, String col, Object value) {
        if (value != null && existingCols.contains(col.toLowerCase(Locale.ROOT))) {
            values.put(col, value);
        }
    }

    private static void writeAll(Path outBase, Map<String, String> files) throws Exception {
        for (Map.Entry<String, String> e : files.entrySet()) {
            Path p = outBase.resolve(e.getKey());
            Files.createDirectories(p.getParent());
            Files.writeString(p, e.getValue(), StandardCharsets.UTF_8);
        }
    }

    private static String stripPrefix(String tableName, String prefix) {
        if (tableName != null && prefix != null && tableName.startsWith(prefix)) {
            return tableName.substring(prefix.length());
        }
        return tableName;
    }

    private static String toClassName(String name) {
        StringBuilder sb = new StringBuilder();
        for (String part : name.split("_")) {
            if (!part.isEmpty()) {
                sb.append(part.substring(0, 1).toUpperCase(Locale.ROOT)).append(part.substring(1));
            }
        }
        return sb.toString();
    }

    private static boolean isBlank(String s) {
        return s == null || s.isBlank();
    }

    private static String mustEnv(String k) {
        String v = System.getenv(k);
        if (v == null || v.isBlank()) {
            throw new IllegalArgumentException("Missing env: " + k);
        }
        return v;
    }
}
