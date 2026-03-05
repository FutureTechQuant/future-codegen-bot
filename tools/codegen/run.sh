#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUOYI_DIR="${ROOT}/ruoyi"
SQL_DIR="${ROOT}/sql/schema"
OUT_DIR="${ROOT}/out/generated"

MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PWD="${MYSQL_PWD:-root}"

mysql_base=(mysql -h "${MYSQL_HOST}" -P "${MYSQL_PORT}" "-u${MYSQL_USER}" "-p${MYSQL_PWD}")

cd "${RUOYI_DIR}"
ENGINE_FILE="$(git ls-files | grep -E '/CodegenEngine\.java$' | head -n 1 || true)"
if [[ -z "${ENGINE_FILE}" ]]; then
  echo "ERROR: CodegenEngine.java not found in ruoyi repo"
  exit 10
fi

MODULE_DIR="${ENGINE_FILE%%/src/main/java/*}"
ENGINE_PKG="$(grep -E '^package ' "${ENGINE_FILE}" | head -n1 | sed -E 's/package ([^;]+);/\1/')"
if [[ -z "${MODULE_DIR}" || -z "${ENGINE_PKG}" ]]; then
  echo "ERROR: cannot parse module/package from ${ENGINE_FILE}"
  exit 11
fi

TEST_DIR="${RUOYI_DIR}/${MODULE_DIR}/src/test/java/ci/codegen"
mkdir -p "${TEST_DIR}"

cat > "${TEST_DIR}/CiCodegenTest.java" <<EOF
package ci.codegen;

import cn.iocoder.yudao.module.infra.dal.dataobject.codegen.CodegenColumnDO;
import cn.iocoder.yudao.module.infra.dal.dataobject.codegen.CodegenTableDO;
import cn.iocoder.yudao.module.infra.enums.codegen.CodegenFrontTypeEnum;
import cn.iocoder.yudao.module.infra.enums.codegen.CodegenSceneEnum;
import cn.iocoder.yudao.module.infra.enums.codegen.CodegenTemplateTypeEnum;
import cn.iocoder.yudao.module.infra.framework.codegen.config.CodegenProperties;
import ${ENGINE_PKG}.CodegenEngine;
import org.junit.jupiter.api.Test;

import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.*;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.util.*;

public class CiCodegenTest {

  @Test
  public void generate() throws Exception {
    String url = mustEnv("DB_URL");
    String user = mustEnv("DB_USER");
    String pwd = mustEnv("DB_PWD");
    String outDir = mustEnv("CODEGEN_OUTPUT_DIR");
    String moduleName = mustEnv("CODEGEN_MODULE_NAME");

    CodegenEngine engine = new CodegenEngine();
    CodegenProperties props = new CodegenProperties();
    tryInvoke(props, "setUnitTestEnable", false);

    Field f = CodegenEngine.class.getDeclaredField("codegenProperties");
    f.setAccessible(true);
    f.set(engine, props);

    Method init = CodegenEngine.class.getDeclaredMethod("initGlobalBindingMap");
    init.setAccessible(true);
    init.invoke(engine);

    try (Connection conn = DriverManager.getConnection(url, user, pwd)) {
      String schema = conn.getCatalog();
      for (String tableName : listAllTables(conn, schema)) {
        String tableComment = getTableComment(conn, schema, tableName);
        List<CodegenColumnDO> columns = listColumns(conn, schema, tableName);

        CodegenTableDO table = new CodegenTableDO();
        tryInvoke(table, "setTableName", tableName);
        tryInvoke(table, "setComment", tableComment);

        table.setModuleName(moduleName);
        table.setBusinessName(tableName);
        table.setClassName(toClassName(tableName));

        table.setFrontType(CodegenFrontTypeEnum.VUE3.getType());
        table.setTemplateType(pickSimpleTemplateType());
        table.setScene(CodegenSceneEnum.values()[0].getScene());

        Map<String, String> files = engine.execute(table, columns, Collections.emptyList(), Collections.emptyList());
        writeAll(outDir, files);
      }
    }
  }

  private static Integer pickSimpleTemplateType() {
    for (CodegenTemplateTypeEnum e : CodegenTemplateTypeEnum.values()) {
      if (e.name().toUpperCase(Locale.ROOT).contains("SIMPLE")) return e.getType();
    }
    return CodegenTemplateTypeEnum.values()[0].getType();
  }

  private static List<String> listAllTables(Connection conn, String schema) throws SQLException {
    List<String> list = new ArrayList<>();
    try (PreparedStatement ps = conn.prepareStatement(
        "select table_name from information_schema.tables where table_schema=? and table_type='BASE TABLE'")) {
      ps.setString(1, schema);
      try (ResultSet rs = ps.executeQuery()) {
        while (rs.next()) list.add(rs.getString(1));
      }
    }
    return list;
  }

  private static String getTableComment(Connection conn, String schema, String table) throws SQLException {
    try (PreparedStatement ps = conn.prepareStatement(
        "select table_comment from information_schema.tables where table_schema=? and table_name=?")) {
      ps.setString(1, schema);
      ps.setString(2, table);
      try (ResultSet rs = ps.executeQuery()) {
        if (rs.next()) return rs.getString(1);
      }
    }
    return "";
  }

  private static List<CodegenColumnDO> listColumns(Connection conn, String schema, String table) throws SQLException {
    List<CodegenColumnDO> list = new ArrayList<>();
    try (PreparedStatement ps = conn.prepareStatement(
        "select column_name, data_type, column_key, is_nullable, column_comment " +
        "from information_schema.columns where table_schema=? and table_name=? order by ordinal_position")) {
      ps.setString(1, schema);
      ps.setString(2, table);
      try (ResultSet rs = ps.executeQuery()) {
        while (rs.next()) {
          String columnName = rs.getString(1);
          String dataType = rs.getString(2);
          boolean pk = "PRI".equalsIgnoreCase(rs.getString(3));
          boolean nullable = "YES".equalsIgnoreCase(rs.getString(4));
          String comment = rs.getString(5);

          CodegenColumnDO c = new CodegenColumnDO();
          tryInvoke(c, "setColumnName", columnName);
          tryInvoke(c, "setComment", comment);

          c.setJavaField(toJavaField(columnName));
          c.setJavaType(mapJavaType(dataType));
          c.setPrimaryKey(pk);
          tryInvoke(c, "setNullable", nullable);

          list.add(c);
        }
      }
    }
    return list;
  }

  private static void writeAll(String outDir, Map<String, String> files) throws Exception {
    Path base = Path.of(outDir);
    for (Map.Entry<String, String> e : files.entrySet()) {
      Path p = base.resolve(e.getKey());
      Files.createDirectories(p.getParent());
      Files.writeString(p, e.getValue(), StandardCharsets.UTF_8);
    }
  }

  private static String toClassName(String name) {
    StringBuilder sb = new StringBuilder();
    for (String part : name.split("_")) {
      if (part.isEmpty()) continue;
      sb.append(part.substring(0, 1).toUpperCase(Locale.ROOT)).append(part.substring(1));
    }
    return sb.toString();
  }

  private static String toJavaField(String name) {
    String cls = toClassName(name);
    return cls.substring(0, 1).toLowerCase(Locale.ROOT) + cls.substring(1);
  }

  private static String mapJavaType(String mysqlType) {
    String t = mysqlType.toLowerCase(Locale.ROOT);
    return switch (t) {
      case "varchar", "char", "text", "longtext", "mediumtext", "tinytext" -> String.class.getName();
      case "bigint" -> Long.class.getName();
      case "int", "integer", "mediumint", "smallint", "tinyint" -> Integer.class.getName();
      case "decimal", "numeric" -> BigDecimal.class.getName();
      case "datetime", "timestamp" -> LocalDateTime.class.getName();
      case "date" -> LocalDate.class.getName();
      case "double" -> Double.class.getName();
      case "float" -> Float.class.getName();
      default -> String.class.getName();
    };
  }

  private static String mustEnv(String k) {
    String v = System.getenv(k);
    if (v == null || v.isBlank()) throw new IllegalArgumentException("Missing env: " + k);
    return v;
  }

  private static void tryInvoke(Object target, String methodName, Object arg) {
    try {
      for (Method m : target.getClass().getMethods()) {
        if (m.getName().equals(methodName) && m.getParameterCount() == 1) {
          m.invoke(target, arg);
          return;
        }
      }
    } catch (Exception ignored) {}
  }
}
EOF

mkdir -p "${OUT_DIR}"
shopt -s nullglob
sql_files=("${SQL_DIR}"/*.sql)
if [[ ${#sql_files[@]} -eq 0 ]]; then
  echo "ERROR: no sql files in ${SQL_DIR}"
  exit 20
fi

"${mysql_base[@]}" -e "SELECT 1" >/dev/null

for f in "${sql_files[@]}"; do
  module="$(basename "${f}" .sql)"
  db="codegen_${module}"
  echo "==> module=${module}, db=${db}, sql=${f}"

  "${mysql_base[@]}" -e "DROP DATABASE IF EXISTS \`${db}\`; CREATE DATABASE \`${db}\` DEFAULT CHARACTER SET utf8mb4;"
  "${mysql_base[@]}" "${db}" < "${f}"

  export DB_URL="jdbc:mysql://${MYSQL_HOST}:${MYSQL_PORT}/${db}?useSSL=false&serverTimezone=UTC&allowPublicKeyRetrieval=true"
  export DB_USER="${MYSQL_USER}"
  export DB_PWD="${MYSQL_PWD}"
  export CODEGEN_MODULE_NAME="${module}"
  export CODEGEN_OUTPUT_DIR="${ROOT}/out/generated/${module}"

  rm -rf "${CODEGEN_OUTPUT_DIR}" && mkdir -p "${CODEGEN_OUTPUT_DIR}"

  mvn -q -f "${RUOYI_DIR}/pom.xml" -pl "${MODULE_DIR}" -am -Dtest=ci.codegen.CiCodegenTest test
done

echo "Generated under ${ROOT}/out/generated"
