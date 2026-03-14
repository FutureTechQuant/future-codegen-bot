package ci.codegen;

import cn.iocoder.yudao.module.infra.enums.codegen.CodegenFrontTypeEnum;
import cn.iocoder.yudao.module.infra.enums.codegen.CodegenSceneEnum;
import cn.iocoder.yudao.module.infra.enums.codegen.CodegenTemplateTypeEnum;
import org.junit.jupiter.api.Test;

import java.sql.*;
import java.util.*;

public class CiImportCodegenMetaTest {

    @Test
    public void importMeta() throws Exception {
        String url = mustEnv("DB_URL");
        String user = mustEnv("DB_USER");
        String pwd = mustEnv("DB_PWD");
        String moduleName = mustEnv("CODEGEN_MODULE_NAME");
        String basePackage = mustEnv("CODEGEN_BASE_PACKAGE");
        String tablePrefix = System.getenv().getOrDefault("CODEGEN_TABLE_PREFIX", moduleName + "_");

        try (Connection conn = DriverManager.getConnection(url, user, pwd)) {
            conn.setAutoCommit(false);
            String schema = conn.getCatalog();

            ensureInfraTableExists(conn, schema, "infra_codegen_table");
            ensureInfraTableExists(conn, schema, "infra_codegen_column");

            List<TableMeta> businessTables = listBusinessTables(conn, schema, tablePrefix);
            if (businessTables.isEmpty()) {
                throw new IllegalStateException("No business tables found for prefix: " + tablePrefix);
            }

            Set<String> codegenTableCols = loadTableColumns(conn, schema, "infra_codegen_table");
            Set<String> codegenColumnCols = loadTableColumns(conn, schema, "infra_codegen_column");

            purgeExisting(conn, tablePrefix);

            Integer templateType = pickSimpleTemplateType();
            Integer frontType = resolveVue3FrontType();
            Integer scene = CodegenSceneEnum.values()[0].getScene();

            for (TableMeta table : businessTables) {
                long tableId = insertCodegenTable(
                        conn, codegenTableCols, table, moduleName, basePackage, tablePrefix,
                        templateType, frontType, scene
                );

                List<ColumnMeta> columns = listColumns(conn, schema, table.tableName);
                for (ColumnMeta col : columns) {
                    insertCodegenColumn(conn, codegenColumnCols, tableId, col);
                }
            }

            conn.commit();
        }
    }

    private static void ensureInfraTableExists(Connection conn, String schema, String tableName) throws SQLException {
        String sql =
                "SELECT COUNT(*) " +
                "FROM information_schema.tables " +
                "WHERE table_schema = ? AND table_name = ?";

        try (PreparedStatement ps = conn.prepareStatement(sql)) {
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

    private static List<TableMeta> listBusinessTables(Connection conn, String schema, String tablePrefix) throws SQLException {
        String sql =
                "SELECT table_name, table_comment " +
                "FROM information_schema.tables " +
                "WHERE table_schema = ? " +
                "AND table_type = 'BASE TABLE' " +
                "AND table_name LIKE ? " +
                "ORDER BY table_name";

        List<TableMeta> list = new ArrayList<>();
        try (PreparedStatement ps = conn.prepareStatement(sql)) {
            ps.setString(1, schema);
            ps.setString(2, tablePrefix + "%");
            try (ResultSet rs = ps.executeQuery()) {
                while (rs.next()) {
                    list.add(new TableMeta(
                            rs.getString("table_name"),
                            nvl(rs.getString("table_comment"))
                    ));
                }
            }
        }
        return list;
    }

    private static List<ColumnMeta> listColumns(Connection conn, String schema, String tableName) throws SQLException {
        String sql =
                "SELECT column_name, data_type, column_key, is_nullable, column_comment, ordinal_position " +
                "FROM information_schema.columns " +
                "WHERE table_schema = ? AND table_name = ? " +
                "ORDER BY ordinal_position";

        List<ColumnMeta> list = new ArrayList<>();
        try (PreparedStatement ps = conn.prepareStatement(sql)) {
            ps.setString(1, schema);
            ps.setString(2, tableName);
            try (ResultSet rs = ps.executeQuery()) {
                while (rs.next()) {
                    list.add(new ColumnMeta(
                            rs.getString("column_name"),
                            rs.getString("data_type"),
                            "PRI".equalsIgnoreCase(rs.getString("column_key")),
                            "YES".equalsIgnoreCase(rs.getString("is_nullable")),
                            nvl(rs.getString("column_comment")),
                            rs.getInt("ordinal_position")
                    ));
                }
            }
        }
        return list;
    }

    private static Set<String> loadTableColumns(Connection conn, String schema, String tableName) throws SQLException {
        String sql =
                "SELECT column_name " +
                "FROM information_schema.columns " +
                "WHERE table_schema = ? AND table_name = ? " +
                "ORDER BY ordinal_position";

        Set<String> cols = new LinkedHashSet<>();
        try (PreparedStatement ps = conn.prepareStatement(sql)) {
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

    private static void purgeExisting(Connection conn, String tablePrefix) throws SQLException {
        List<Long> ids = new ArrayList<>();

        String selectSql = "SELECT id FROM infra_codegen_table WHERE table_name LIKE ?";
        try (PreparedStatement ps = conn.prepareStatement(selectSql)) {
            ps.setString(1, tablePrefix + "%");
            try (ResultSet rs = ps.executeQuery()) {
                while (rs.next()) {
                    ids.add(rs.getLong(1));
                }
            }
        }

        if (!ids.isEmpty()) {
            String inSql = String.join(",", Collections.nCopies(ids.size(), "?"));
            String deleteColumnSql = "DELETE FROM infra_codegen_column WHERE table_id IN (" + inSql + ")";
            try (PreparedStatement ps = conn.prepareStatement(deleteColumnSql)) {
                for (int i = 0; i < ids.size(); i++) {
                    ps.setLong(i + 1, ids.get(i));
                }
                ps.executeUpdate();
            }
        }

        String deleteTableSql = "DELETE FROM infra_codegen_table WHERE table_name LIKE ?";
        try (PreparedStatement ps = conn.prepareStatement(deleteTableSql)) {
            ps.setString(1, tablePrefix + "%");
            ps.executeUpdate();
        }
    }

    private static long insertCodegenTable(Connection conn,
                                           Set<String> existingCols,
                                           TableMeta table,
                                           String moduleName,
                                           String basePackage,
                                           String tablePrefix,
                                           Integer templateType,
                                           Integer frontType,
                                           Integer scene) throws SQLException {
        String tableName = table.tableName;
        String tableComment = table.tableComment;
        String className = toClassName(tableName);
        String businessName = stripPrefix(tableName, tablePrefix);
        String packageName = basePackage + ".module." + moduleName;

        LinkedHashMap<String, Object> values = new LinkedHashMap<>();
        putIfHas(existingCols, values, "table_name", tableName);
        putIfHas(existingCols, values, "table_comment", tableComment);
        putIfHas(existingCols, values, "comment", tableComment);
        putIfHas(existingCols, values, "class_name", className);
        putIfHas(existingCols, values, "class_comment", tableComment);
        putIfHas(existingCols, values, "author", "future-codegen-bot");
        putIfHas(existingCols, values, "template_type", templateType);
        putIfHas(existingCols, values, "module_name", moduleName);
        putIfHas(existingCols, values, "business_name", businessName);
        putIfHas(existingCols, values, "package_name", packageName);
        putIfHas(existingCols, values, "scene", scene);
        putIfHas(existingCols, values, "front_type", frontType);
        putIfHas(existingCols, values, "menu_name", tableComment.isBlank() ? className : tableComment);
        putIfHas(existingCols, values, "parent_menu_id", 0L);

        return insertAndReturnId(conn, "infra_codegen_table", values, tableName);
    }

    private static void insertCodegenColumn(Connection conn,
                                            Set<String> existingCols,
                                            long tableId,
                                            ColumnMeta col) throws SQLException {
        String javaType = mapJavaType(col.dataType);
        String javaField = toJavaField(col.columnName);
        int queryFlag = guessQueryFlag(col.columnName) ? 1 : 0;
        String htmlType = guessHtmlType(col);

        LinkedHashMap<String, Object> values = new LinkedHashMap<>();
        putIfHas(existingCols, values, "table_id", tableId);
        putIfHas(existingCols, values, "column_name", col.columnName);
        putIfHas(existingCols, values, "column_comment", col.columnComment);
        putIfHas(existingCols, values, "comment", col.columnComment);
        putIfHas(existingCols, values, "data_type", col.dataType);
        putIfHas(existingCols, values, "java_type", javaType);
        putIfHas(existingCols, values, "java_field", javaField);
        putIfHas(existingCols, values, "dict_type", "");
        putIfHas(existingCols, values, "example", "");
        putIfHas(existingCols, values, "sort", col.ordinalPosition);
        putIfHas(existingCols, values, "ordinal_position", col.ordinalPosition);
        putIfHas(existingCols, values, "nullable", col.nullable ? 1 : 0);
        putIfHas(existingCols, values, "required", (!col.nullable && !col.primaryKey) ? 1 : 0);
        putIfHas(existingCols, values, "primary_key", col.primaryKey ? 1 : 0);
        putIfHas(existingCols, values, "primary", col.primaryKey ? 1 : 0);
        putIfHas(existingCols, values, "pk", col.primaryKey ? 1 : 0);
        putIfHas(existingCols, values, "html_type", htmlType);
        putIfHas(existingCols, values, "create_operation", col.primaryKey ? 0 : 1);
        putIfHas(existingCols, values, "update_operation", col.primaryKey ? 0 : 1);
        putIfHas(existingCols, values, "list_operation", 1);
        putIfHas(existingCols, values, "list_operation_result", 1);
        putIfHas(existingCols, values, "query_operation", queryFlag);
        putIfHas(existingCols, values, "whether_create", col.primaryKey ? 0 : 1);
        putIfHas(existingCols, values, "whether_update", col.primaryKey ? 0 : 1);
        putIfHas(existingCols, values, "whether_list", 1);
        putIfHas(existingCols, values, "whether_result", 1);
        putIfHas(existingCols, values, "whether_query", queryFlag);
        putIfHas(existingCols, values, "whether_required", (!col.nullable && !col.primaryKey) ? 1 : 0);

        insert(conn, "infra_codegen_column", values);
    }

    private static void putIfHas(Set<String> existingCols, Map<String, Object> values, String col, Object value) {
        if (value == null) {
            return;
        }
        if (existingCols.contains(col.toLowerCase(Locale.ROOT))) {
            values.put(col, value);
        }
    }

    private static void insert(Connection conn, String table, LinkedHashMap<String, Object> values) throws SQLException {
        if (values.isEmpty()) {
            throw new IllegalStateException("No insertable values for table " + table);
        }

        String columns = String.join(", ", values.keySet());
        String placeholders = String.join(", ", Collections.nCopies(values.size(), "?"));
        String sql = "INSERT INTO " + table + " (" + columns + ") VALUES (" + placeholders + ")";

        try (PreparedStatement ps = conn.prepareStatement(sql)) {
            int idx = 1;
            for (Object v : values.values()) {
                ps.setObject(idx++, v);
            }
            ps.executeUpdate();
        }
    }

    private static long insertAndReturnId(Connection conn, String table,
                                          LinkedHashMap<String, Object> values,
                                          String tableName) throws SQLException {
        if (values.isEmpty()) {
            throw new IllegalStateException("No insertable values for table " + table);
        }

        String columns = String.join(", ", values.keySet());
        String placeholders = String.join(", ", Collections.nCopies(values.size(), "?"));
        String sql = "INSERT INTO " + table + " (" + columns + ") VALUES (" + placeholders + ")";

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

        String selectIdSql = "SELECT id FROM infra_codegen_table WHERE table_name = ?";
        try (PreparedStatement ps = conn.prepareStatement(selectIdSql)) {
            ps.setString(1, tableName);
            try (ResultSet rs = ps.executeQuery()) {
                if (rs.next()) {
                    return rs.getLong(1);
                }
            }
        }

        throw new IllegalStateException("Failed to retrieve inserted id for " + tableName);
    }

    private static Integer resolveVue3FrontType() {
        try {
            for (CodegenFrontTypeEnum e : CodegenFrontTypeEnum.values()) {
                String name = e.name().toUpperCase(Locale.ROOT);
                if (name.contains("VUE3") && name.contains("ELEMENT")) {
                    return e.getType();
                }
            }
            for (CodegenFrontTypeEnum e : CodegenFrontTypeEnum.values()) {
                String name = e.name().toUpperCase(Locale.ROOT);
                if (name.contains("VUE3")) {
                    return e.getType();
                }
            }
            return null;
        } catch (Exception ignore) {
            return null;
        }
    }

    private static Integer pickSimpleTemplateType() {
        for (CodegenTemplateTypeEnum e : CodegenTemplateTypeEnum.values()) {
            if (e.name().toUpperCase(Locale.ROOT).contains("SIMPLE")) {
                return e.getType();
            }
        }
        return CodegenTemplateTypeEnum.values()[0].getType();
    }

    private static String mapJavaType(String mysqlType) {
        String t = mysqlType == null ? "" : mysqlType.toLowerCase(Locale.ROOT);
        switch (t) {
            case "varchar":
            case "char":
            case "text":
            case "longtext":
            case "mediumtext":
            case "tinytext":
                return "String";
            case "bigint":
                return "Long";
            case "int":
            case "integer":
            case "mediumint":
            case "smallint":
            case "tinyint":
                return "Integer";
            case "decimal":
            case "numeric":
                return "BigDecimal";
            case "datetime":
            case "timestamp":
                return "LocalDateTime";
            case "date":
                return "LocalDate";
            case "double":
                return "Double";
            case "float":
                return "Float";
            case "bit":
            case "boolean":
                return "Boolean";
            default:
                return "String";
        }
    }

    private static String guessHtmlType(ColumnMeta col) {
        String t = col.dataType.toLowerCase(Locale.ROOT);
        if (t.contains("text")) {
            return "textarea";
        }
        if ("date".equals(t) || "datetime".equals(t) || "timestamp".equals(t)) {
            return "datetime";
        }
        return "input";
    }

    private static boolean guessQueryFlag(String columnName) {
        String c = columnName.toLowerCase(Locale.ROOT);
        return c.endsWith("name") || c.endsWith("status") || c.endsWith("type") || c.contains("title");
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
            if (part.isEmpty()) {
                continue;
            }
            sb.append(part.substring(0, 1).toUpperCase(Locale.ROOT)).append(part.substring(1));
        }
        return sb.toString();
    }

    private static String toJavaField(String name) {
        String cls = toClassName(name);
        return cls.substring(0, 1).toLowerCase(Locale.ROOT) + cls.substring(1);
    }

    private static String mustEnv(String k) {
        String v = System.getenv(k);
        if (v == null || v.isBlank()) {
            throw new IllegalArgumentException("Missing env: " + k);
        }
        return v;
    }

    private static String nvl(String s) {
        return s == null ? "" : s;
    }

    private static final class TableMeta {
        private final String tableName;
        private final String tableComment;

        private TableMeta(String tableName, String tableComment) {
            this.tableName = tableName;
            this.tableComment = tableComment;
        }
    }

    private static final class ColumnMeta {
        private final String columnName;
        private final String dataType;
        private final boolean primaryKey;
        private final boolean nullable;
        private final String columnComment;
        private final int ordinalPosition;

        private ColumnMeta(String columnName, String dataType, boolean primaryKey,
                           boolean nullable, String columnComment, int ordinalPosition) {
            this.columnName = columnName;
            this.dataType = dataType;
            this.primaryKey = primaryKey;
            this.nullable = nullable;
            this.columnComment = columnComment;
            this.ordinalPosition = ordinalPosition;
        }
    }
}
