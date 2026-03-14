package ci.codegen;

import cn.iocoder.yudao.module.infra.dal.dataobject.codegen.CodegenColumnDO;
import cn.iocoder.yudao.module.infra.dal.dataobject.codegen.CodegenTableDO;
import cn.iocoder.yudao.module.infra.enums.codegen.CodegenSceneEnum;
import cn.iocoder.yudao.module.infra.enums.codegen.CodegenTemplateTypeEnum;
import org.junit.jupiter.api.Test;

import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.*;
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
    String tablePrefix = System.getenv().getOrDefault("CODEGEN_TABLE_PREFIX", moduleName + "_");

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
      List<CodegenTableDO> tables = listCodegenTables(conn, tablePrefix, moduleName);
      if (tables.isEmpty()) {
        throw new IllegalStateException(
            "No rows found in infra_codegen_table for prefix: " + tablePrefix +
            ". Please import business tables into infra_codegen_table / infra_codegen_column first.");
      }

      Integer frontType = resolveVue3FrontType();
      Integer templateType = pickSimpleTemplateType();
      Integer scene = CodegenSceneEnum.values()[0].getScene();

      for (CodegenTableDO table : tables) {
        if (frontType != null) {
          table.setFrontType(frontType);
        }
        if (table.getTemplateType() == null) {
          table.setTemplateType(templateType);
        }
        if (table.getScene() == null) {
          table.setScene(scene);
        }
        if (isBlank(table.getModuleName())) {
          table.setModuleName(moduleName);
        }
        if (isBlank(table.getBusinessName())) {
          table.setBusinessName(defaultBusinessName(table.getTableName(), tablePrefix));
        }
        if (isBlank(table.getClassName())) {
          table.setClassName(toClassName(table.getTableName()));
        }

        List<CodegenColumnDO> columns = listCodegenColumns(conn, table.getId());
        if (columns.isEmpty()) {
          throw new IllegalStateException("No rows found in infra_codegen_column for tableId=" + table.getId());
        }

        @SuppressWarnings("unchecked")
        Map<String, String> files = (Map<String, String>) invokeExecute(engineClz, engine, table, columns);
        writeAll(outDir, files);
      }
    }
  }

  private static List<CodegenTableDO> listCodegenTables(Connection conn, String tablePrefix, String moduleName) throws Exception {
    String sql = """
        SELECT *
        FROM infra_codegen_table
        WHERE table_name LIKE ?
           OR module_name = ?
           OR business_name LIKE ?
        ORDER BY id
        """;
    List<CodegenTableDO> list = new ArrayList<>();
    try (PreparedStatement ps = conn.prepareStatement(sql)) {
      ps.setString(1, tablePrefix + "%");
      ps.setString(2, moduleName);
      ps.setString(3, tablePrefix + "%");
      try (ResultSet rs = ps.executeQuery()) {
        while (rs.next()) {
          CodegenTableDO table = new CodegenTableDO();
          hydrateFromResultSet(rs, table);
          if (isBlank(table.getTableName())) {
            continue;
          }
          list.add(table);
        }
      }
    }
    return list;
  }

  private static List<CodegenColumnDO> listCodegenColumns(Connection conn, Long tableId) throws Exception {
    String sql = """
        SELECT *
        FROM infra_codegen_column
        WHERE table_id = ?
        ORDER BY id
        """;
    List<CodegenColumnDO> list = new ArrayList<>();
    try (PreparedStatement ps = conn.prepareStatement(sql)) {
      ps.setLong(1, tableId);
      try (ResultSet rs = ps.executeQuery()) {
        while (rs.next()) {
          CodegenColumnDO col = new CodegenColumnDO();
          hydrateFromResultSet(rs, col);
          list.add(col);
        }
      }
    }
    return list;
  }

  private static void hydrateFromResultSet(ResultSet rs, Object bean) throws Exception {
    ResultSetMetaData md = rs.getMetaData();
    for (int i = 1; i <= md.getColumnCount(); i++) {
      String column = md.getColumnLabel(i);
      Object value = rs.getObject(i);
      if (value == null) {
        continue;
      }
      tryInvokeSetter(bean, toSetter(column), value);
    }
  }

  private static String toSetter(String column) {
    StringBuilder sb = new StringBuilder("set");
    boolean upper = true;
    for (char ch : column.toCharArray()) {
      if (ch == '_') {
        upper = true;
        continue;
      }
      sb.append(upper ? Character.toUpperCase(ch) : ch);
      upper = false;
    }
    return sb.toString();
  }

  private static void tryInvokeSetter(Object target, String setter, Object value) {
    for (Method m : target.getClass().getMethods()) {
      if (!m.getName().equals(setter) || m.getParameterCount() != 1) {
        continue;
      }
      try {
        Class<?> pt = m.getParameterTypes()[0];
        m.invoke(target, convertValue(value, pt));
        return;
      } catch (Exception ignore) {
      }
    }
  }

  private static Object convertValue(Object value, Class<?> targetType) {
    if (value == null) return null;
    if (targetType.isInstance(value)) return value;

    String s = String.valueOf(value);

    if (targetType == String.class) return s;
    if (targetType == Integer.class || targetType == int.class) return Integer.valueOf(s);
    if (targetType == Long.class || targetType == long.class) return Long.valueOf(s);
    if (targetType == Boolean.class || targetType == boolean.class) {
      if (value instanceof Number n) return n.intValue() != 0;
      return "1".equals(s) || "true".equalsIgnoreCase(s);
    }
    return value;
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

  private static void writeAll(String outDir, Map<String, String> files) throws Exception {
    Path base = Path.of(outDir);
    for (Map.Entry<String, String> e : files.entrySet()) {
      Path p = base.resolve(e.getKey());
      Files.createDirectories(p.getParent());
      Files.writeString(p, e.getValue(), StandardCharsets.UTF_8);
    }
  }

  private static String defaultBusinessName(String tableName, String prefix) {
    if (tableName != null && prefix != null && tableName.startsWith(prefix)) {
      return tableName.substring(prefix.length());
    }
    return tableName;
  }

  private static String toClassName(String name) {
    StringBuilder sb = new StringBuilder();
    for (String part : name.split("_")) {
      if (part.isEmpty()) continue;
      sb.append(part.substring(0, 1).toUpperCase(Locale.ROOT)).append(part.substring(1));
    }
    return sb.toString();
  }

  private static boolean isBlank(String s) {
    return s == null || s.isBlank();
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
