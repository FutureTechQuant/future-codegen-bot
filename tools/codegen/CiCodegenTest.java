package ci.codegen;

import cn.iocoder.yudao.module.infra.dal.dataobject.codegen.CodegenColumnDO;
import cn.iocoder.yudao.module.infra.dal.dataobject.codegen.CodegenTableDO;
import cn.iocoder.yudao.module.infra.enums.codegen.CodegenSceneEnum;
import cn.iocoder.yudao.module.infra.enums.codegen.CodegenTemplateTypeEnum;
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
    String engineClassName = mustEnv("CODEGEN_ENGINE_CLASS");
    String url = mustEnv("DB_URL");
    String user = mustEnv("DB_USER");
    String pwd = mustEnv("DB_PWD");
    String outDir = mustEnv("CODEGEN_OUTPUT_DIR");
    String moduleName = mustEnv("CODEGEN_MODULE_NAME");
    String basePackage = mustEnv("CODEGEN_BASE_PACKAGE");

    Class<?> engineClz = Class.forName(engineClassName);
    Object engine = engineClz.getDeclaredConstructor().newInstance();

    Object props = tryNew("cn.iocoder.yudao.module.infra.framework.codegen.config.CodegenProperties");
    if (props != null) {
      tryInvoke(props, "setUnitTestEnable", false);
      tryInvoke(props, "setBasePackage", basePackage);
      trySetField(engineClz, engine, "codegenProperties", props);
    }
    tryInvoke(engine, "initGlobalBindingMap");

    try (Connection conn = DriverManager.getConnection(url, user, pwd)) {
      String schema = conn.getCatalog();

      Integer frontType = resolveVue3FrontType();
      Integer templateType = pickSimpleTemplateType();
      Integer scene = CodegenSceneEnum.values()[0].getScene();

      for (String tableName : listAllTables(conn, schema)) {
        String tableComment = getTableComment(conn, schema, tableName);
        List<CodegenColumnDO> columns = listColumns(conn, schema, tableName);

        CodegenTableDO table = new CodegenTableDO();
        tryInvoke(table, "setTableName", tableName);
        tryInvoke(table, "setComment", tableComment);

        table.setModuleName(moduleName);
        table.setBusinessName(tableName);
        table.setClassName(toClassName(tableName));

        if (frontType != null) {
          table.setFrontType(frontType);
        }

        table.setTemplateType(templateType);
        table.setScene(scene);

        @SuppressWarnings("unchecked")
        Map<String, String> files = (Map<String, String>) invokeExecute(engineClz, engine, table, columns);
        writeAll(outDir, files);
      }
    }
  }

  private static Object invokeExecute(Class<?> engineClz, Object engine,
                                      CodegenTableDO table, List<CodegenColumnDO> columns) throws Exception {
    for (Method m : engineClz.getMethods()) {
      if (!m.getName().equals("execute")) continue;
      int n = m.getParameterCount();

      if (n == 5) {
        Object dbTypeMysql = resolveDbTypeMysql();
        List<CodegenTableDO> subTables = Collections.emptyList();
        List<List<CodegenColumnDO>> subColumns = Collections.emptyList();
        return m.invoke(engine, dbTypeMysql, table, columns, subTables, subColumns);
      }
      if (n == 4) {
        List<?> subTables = Collections.emptyList();
        List<?> subColumns = Collections.emptyList();
        return m.invoke(engine, table, columns, subTables, subColumns);
      }
    }
    throw new IllegalStateException("No compatible CodegenEngine.execute(...) found");
  }

  private static Object resolveDbTypeMysql() throws Exception {
    Class<?> c = Class.forName("com.baomidou.mybatisplus.annotation.DbType");
    @SuppressWarnings("unchecked")
    Class<? extends Enum> ec = (Class<? extends Enum>) c;
    return Enum.valueOf(ec, "MYSQL");
  }

  private static Integer resolveVue3FrontType() {
    try {
      Class<?> enumClz = Class.forName("cn.iocoder.yudao.module.infra.enums.codegen.CodegenFrontTypeEnum");
      Object[] constants = enumClz.getEnumConstants();
      if (constants == null || constants.length == 0) return null;

      Object best = null;
      for (Object e : constants) {
        String name = ((Enum<?>) e).name().toUpperCase(Locale.ROOT);
        if (name.contains("VUE3") && name.contains("ELEMENT")) { best = e; break; }
        if (best == null && name.contains("VUE3")) best = e;
      }
      if (best == null) return null;

      Method getType = enumClz.getMethod("getType");
      Object v = getType.invoke(best);
      if (v instanceof Integer i) return i;
      if (v instanceof Number n) return n.intValue();
      return Integer.valueOf(String.valueOf(v));
    } catch (Exception ignore) {
      return null;
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

  private static Object tryNew(String className) {
    try {
      Class<?> c = Class.forName(className);
      return c.getDeclaredConstructor().newInstance();
    } catch (Exception ignore) {
      return null;
    }
  }

  private static void trySetField(Class<?> clz, Object target, String fieldName, Object value) {
    try {
      Field f = clz.getDeclaredField(fieldName);
      f.setAccessible(true);
      f.set(target, value);
    } catch (Exception ignore) {}
  }

  private static void tryInvoke(Object target, String methodName, Object arg) {
    try {
      for (Method m : target.getClass().getMethods()) {
        if (m.getName().equals(methodName) && m.getParameterCount() == 1) {
          m.invoke(target, arg);
          return;
        }
      }
    } catch (Exception ignore) {}
  }

  private static void tryInvoke(Object target, String methodName) {
    try {
      Method m = target.getClass().getDeclaredMethod(methodName);
      m.setAccessible(true);
      m.invoke(target);
    } catch (Exception ignore) {}
  }
}
