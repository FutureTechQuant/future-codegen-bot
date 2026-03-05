SET NAMES utf8mb4;
SET FOREIGN_KEY_CHECKS = 0;

-- =========================================================
-- Talent 业务域表
-- =========================================================

-- 1) 服务品类（树）
DROP TABLE IF EXISTS `talent_category`;
CREATE TABLE `talent_category` (
  `id` bigint NOT NULL AUTO_INCREMENT COMMENT '品类ID',
  `parent_id` bigint NOT NULL DEFAULT 0 COMMENT '父级品类ID，0为根',
  `name` varchar(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL COMMENT '品类名称',
  `sort` int NOT NULL DEFAULT 0 COMMENT '排序',
  `status` tinyint NOT NULL DEFAULT 0 COMMENT '状态：0启用 1停用',
  `description` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT '描述',

  `creator` varchar(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NULL DEFAULT '' COMMENT '创建者',
  `create_time` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  `updater` varchar(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NULL DEFAULT '' COMMENT '更新者',
  `update_time` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '更新时间',
  `deleted` bit(1) NOT NULL DEFAULT b'0' COMMENT '是否删除',
  `tenant_id` bigint NOT NULL DEFAULT 0 COMMENT '租户编号',

  PRIMARY KEY (`id`) USING BTREE,
  INDEX `idx_parent_id`(`parent_id` ASC) USING BTREE,
  INDEX `idx_status_sort`(`status` ASC, `sort` ASC) USING BTREE
) ENGINE = InnoDB
  CHARACTER SET = utf8mb4 COLLATE = utf8mb4_unicode_ci
  COMMENT = '达人-服务品类';


-- 2) 达人核心表（高频、可筛选、可排序、对接审批）
DROP TABLE IF EXISTS `talent_provider`;
CREATE TABLE `talent_provider` (
  `id` bigint NOT NULL AUTO_INCREMENT COMMENT '达人ID',
  `user_id` bigint NOT NULL COMMENT '用户ID（member_user.id）',

  `provider_type` tinyint NOT NULL DEFAULT 0 COMMENT '达人类型：10心理咨询 20健身 30旅游搭子...（字典）',
  `status` tinyint NOT NULL DEFAULT 0 COMMENT '达人系统状态：0待激活 1申请入驻/待审 2启用 3停用 4封禁',
  `audit_status` tinyint NOT NULL DEFAULT 0 COMMENT '审核状态：0草稿 10待审 20通过 30拒绝',
  `reject_reason` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT '拒绝原因',
  `bpm_process_instance_id` bigint NULL DEFAULT NULL COMMENT 'BPM流程实例ID（达人自填审批用，可选）',

  `real_name` varchar(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL COMMENT '对外展示姓名',
  `avatar` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT '头像URL',
  `gender` tinyint NOT NULL DEFAULT 0 COMMENT '性别：0未知 1男 2女',

  -- 自填/声明字段（可能造假；可信值建议走 talent_provider_verify_stat）
  `age_years` decimal(4,1) UNSIGNED NULL DEFAULT NULL COMMENT '年龄（自填，0.1精度）',
  `height_cm` smallint UNSIGNED NULL DEFAULT NULL COMMENT '身高(cm)（自填）',
  `weight_kg` smallint UNSIGNED NULL DEFAULT NULL COMMENT '体重(kg)（自填）',
  `work_years` tinyint UNSIGNED NOT NULL DEFAULT 0 COMMENT '从业年限（自填）',
  `occupation_title` varchar(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NULL DEFAULT NULL COMMENT '职业/职称（自填，展示用）',

  `area_id` int NULL DEFAULT NULL COMMENT '所在地区域ID（自填）',
  `city` varchar(32) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NULL DEFAULT NULL COMMENT '服务城市（自填）',
  `district` varchar(32) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NULL DEFAULT NULL COMMENT '服务区域（自填）',

  `base_price` decimal(10,2) NULL DEFAULT NULL COMMENT '展示基准价（自填）',
  `currency` varchar(8) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT 'CNY' COMMENT '币种',
  `service_mode` tinyint NOT NULL DEFAULT 0 COMMENT '服务方式：0未知 1线上 2线下 3线上+线下',
  `service_status` tinyint NOT NULL DEFAULT 1 COMMENT '服务状态：1可预约 2忙碌 0休息',

  `view_count` int NOT NULL DEFAULT 0 COMMENT '浏览量',
  `like_count` int NOT NULL DEFAULT 0 COMMENT '被喜欢/收藏次数',

  `creator` varchar(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NULL DEFAULT '' COMMENT '创建者',
  `create_time` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  `updater` varchar(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NULL DEFAULT '' COMMENT '更新者',
  `update_time` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '更新时间',
  `deleted` bit(1) NOT NULL DEFAULT b'0' COMMENT '是否删除',
  `tenant_id` bigint NOT NULL DEFAULT 0 COMMENT '租户编号',

  PRIMARY KEY (`id`) USING BTREE,
  UNIQUE INDEX `uk_tenant_user_type`(`tenant_id` ASC, `user_id` ASC, `provider_type` ASC, `deleted` ASC) USING BTREE,
  INDEX `idx_user_id`(`user_id` ASC) USING BTREE,
  INDEX `idx_tenant_type`(`tenant_id` ASC, `provider_type` ASC) USING BTREE,
  INDEX `idx_tenant_status`(`tenant_id` ASC, `status` ASC) USING BTREE,
  INDEX `idx_tenant_audit`(`tenant_id` ASC, `audit_status` ASC) USING BTREE,
  INDEX `idx_tenant_city`(`tenant_id` ASC, `city` ASC, `district` ASC) USING BTREE,
  INDEX `idx_tenant_proc_inst`(`tenant_id` ASC, `bpm_process_instance_id` ASC) USING BTREE
) ENGINE = InnoDB
  CHARACTER SET = utf8mb4 COLLATE = utf8mb4_unicode_ci
  COMMENT = '达人核心表（高频）';


-- 3) 达人扩展资料表（低频、大字段、JSON/富文本/媒体）
DROP TABLE IF EXISTS `talent_provider_profile`;
CREATE TABLE `talent_provider_profile` (
  `id` bigint NOT NULL COMMENT '达人ID（关联 talent_provider.id）',

  `service_tags` json NULL DEFAULT NULL COMMENT '服务标签（展示向）JSON数组',
  `specialty_json` json NULL DEFAULT NULL COMMENT '擅长领域JSON数组',
  `languages_json` json NULL DEFAULT NULL COMMENT '语言能力JSON数组',

  `bio` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NULL COMMENT '个人简介/欢迎语',
  `media_photos` json NULL DEFAULT NULL COMMENT '照片墙URL数组',
  `media_voice` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NULL DEFAULT NULL COMMENT '语音招呼URL',
  `media_video` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NULL DEFAULT NULL COMMENT '视频介绍URL',

  `marital_status` tinyint NOT NULL DEFAULT 0 COMMENT '婚姻状态：0未知 1未婚 2离异 3已婚 4丧偶',
  `education_level` tinyint NOT NULL DEFAULT 0 COMMENT '学历：0未知 1高中及以下 2大专 3本科 4硕士 5博士',
  `school_name` varchar(128) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NULL DEFAULT NULL COMMENT '毕业院校',
  `major` varchar(128) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NULL DEFAULT NULL COMMENT '专业',

  `creator` varchar(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NULL DEFAULT '' COMMENT '创建者',
  `create_time` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  `updater` varchar(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NULL DEFAULT '' COMMENT '更新者',
  `update_time` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '更新时间',
  `deleted` bit(1) NOT NULL DEFAULT b'0' COMMENT '是否删除',
  `tenant_id` bigint NOT NULL DEFAULT 0 COMMENT '租户编号',

  PRIMARY KEY (`id`) USING BTREE,
  INDEX `idx_tenant`(`tenant_id` ASC) USING BTREE
) ENGINE = InnoDB
  CHARACTER SET = utf8mb4 COLLATE = utf8mb4_unicode_ci
  COMMENT = '达人资料扩展表（低频）';


-- 4) 达人-品类关联（一个达人可提供多个品类）
DROP TABLE IF EXISTS `talent_provider_category`;
CREATE TABLE `talent_provider_category` (
  `id` bigint NOT NULL AUTO_INCREMENT COMMENT '主键',
  `provider_id` bigint NOT NULL COMMENT 'talent_provider.id',
  `category_id` bigint NOT NULL COMMENT 'talent_category.id',
  `is_primary` bit(1) NOT NULL DEFAULT b'0' COMMENT '是否主品类',

  `creator` varchar(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NULL DEFAULT '' COMMENT '创建者',
  `create_time` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  `updater` varchar(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NULL DEFAULT '' COMMENT '更新者',
  `update_time` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '更新时间',
  `deleted` bit(1) NOT NULL DEFAULT b'0' COMMENT '是否删除',
  `tenant_id` bigint NOT NULL DEFAULT 0 COMMENT '租户编号',

  PRIMARY KEY (`id`) USING BTREE,
  UNIQUE INDEX `uk_provider_category`(`tenant_id` ASC, `provider_id` ASC, `category_id` ASC, `deleted` ASC) USING BTREE,
  INDEX `idx_provider`(`provider_id` ASC) USING BTREE,
  INDEX `idx_category`(`category_id` ASC) USING BTREE
) ENGINE = InnoDB
  CHARACTER SET = utf8mb4 COLLATE = utf8mb4_unicode_ci
  COMMENT = '达人-达人品类关联';


-- 5) 达人-标签关联（复用 member_tag）
DROP TABLE IF EXISTS `talent_provider_tag`;
CREATE TABLE `talent_provider_tag` (
  `id` bigint NOT NULL AUTO_INCREMENT COMMENT '主键',
  `provider_id` bigint NOT NULL COMMENT 'talent_provider.id',
  `tag_id` bigint NOT NULL COMMENT 'member_tag.id',
  `tag_weight` decimal(6,2) NOT NULL DEFAULT 1.00 COMMENT '达人标签权重/强度（用于排序可选）',

  `creator` varchar(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NULL DEFAULT '' COMMENT '创建者',
  `create_time` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  `updater` varchar(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NULL DEFAULT '' COMMENT '更新者',
  `update_time` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '更新时间',
  `deleted` bit(1) NOT NULL DEFAULT b'0' COMMENT '是否删除',
  `tenant_id` bigint NOT NULL DEFAULT 0 COMMENT '租户编号',

  PRIMARY KEY (`id`) USING BTREE,
  UNIQUE INDEX `uk_provider_tag`(`tenant_id` ASC, `provider_id` ASC, `tag_id` ASC, `deleted` ASC) USING BTREE,
  INDEX `idx_provider`(`provider_id` ASC) USING BTREE,
  INDEX `idx_tag`(`tag_id` ASC) USING BTREE
) ENGINE = InnoDB
  CHARACTER SET = utf8mb4 COLLATE = utf8mb4_unicode_ci
  COMMENT = '达人-达人标签关联';


-- 6) 客户需求单/偏好方案
DROP TABLE IF EXISTS `talent_preference`;
CREATE TABLE `talent_preference` (
  `id` bigint NOT NULL AUTO_INCREMENT COMMENT '偏好/需求ID',
  `user_id` bigint NOT NULL COMMENT '客户 member_user.id',
  `category_id` bigint NULL DEFAULT NULL COMMENT '目标品类 talent_category.id（可选）',
  `mode` tinyint NOT NULL DEFAULT 0 COMMENT '模式：0系统默认 1客户自定义',
  `name` varchar(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT '方案名称（如：找旅游搭子-东京）',
  `decay_default` decimal(6,3) NOT NULL DEFAULT 0.500 COMMENT '默认衰减度（客户不填时用）',
  `status` tinyint NOT NULL DEFAULT 0 COMMENT '状态：0启用 1停用',
  `remark` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT '备注',
  `config_snapshot` json NULL DEFAULT NULL COMMENT '整包配置快照（可选，便于快速加载）',

  `creator` varchar(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NULL DEFAULT '' COMMENT '创建者',
  `create_time` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  `updater` varchar(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NULL DEFAULT '' COMMENT '更新者',
  `update_time` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '更新时间',
  `deleted` bit(1) NOT NULL DEFAULT b'0' COMMENT '是否删除',
  `tenant_id` bigint NOT NULL DEFAULT 0 COMMENT '租户编号',

  PRIMARY KEY (`id`) USING BTREE,
  INDEX `idx_user_status`(`user_id` ASC, `status` ASC) USING BTREE,
  INDEX `idx_category`(`category_id` ASC) USING BTREE
) ENGINE = InnoDB
  CHARACTER SET = utf8mb4 COLLATE = utf8mb4_unicode_ci
  COMMENT = '达人-客户偏好/需求方案';


-- 7) 硬性过滤项
DROP TABLE IF EXISTS `talent_preference_filter`;
CREATE TABLE `talent_preference_filter` (
  `id` bigint NOT NULL AUTO_INCREMENT COMMENT '主键',
  `preference_id` bigint NOT NULL COMMENT 'talent_preference.id',
  `field_code` varchar(32) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL COMMENT '字段编码：gender/city/service_mode/...（自定义枚举）',
  `operator` varchar(8) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '=' COMMENT '操作符：=,!=,IN,BETWEEN,>=,<= 等',
  `value_json` json NOT NULL COMMENT '过滤值（统一JSON，支持数组/区间）',
  `enabled` bit(1) NOT NULL DEFAULT b'1' COMMENT '是否启用',

  `creator` varchar(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NULL DEFAULT '' COMMENT '创建者',
  `create_time` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  `updater` varchar(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NULL DEFAULT '' COMMENT '更新者',
  `update_time` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '更新时间',
  `deleted` bit(1) NOT NULL DEFAULT b'0' COMMENT '是否删除',
  `tenant_id` bigint NOT NULL DEFAULT 0 COMMENT '租户编号',

  PRIMARY KEY (`id`) USING BTREE,
  INDEX `idx_pref_enabled`(`preference_id` ASC, `enabled` ASC) USING BTREE
) ENGINE = InnoDB
  CHARACTER SET = utf8mb4 COLLATE = utf8mb4_unicode_ci
  COMMENT = '达人-偏好硬过滤条件';


-- 8) 数值赋分项
DROP TABLE IF EXISTS `talent_preference_numeric`;
CREATE TABLE `talent_preference_numeric` (
  `id` bigint NOT NULL AUTO_INCREMENT COMMENT '主键',
  `preference_id` bigint NOT NULL COMMENT 'talent_preference.id',
  `field_code` varchar(32) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL COMMENT '字段编码：height_cm/age_years/work_years/base_price等',
  `target_value` decimal(12,3) NOT NULL COMMENT '目标值',
  `full_score` decimal(8,3) NOT NULL DEFAULT 5.000 COMMENT '满分分值（命中目标时）',
  `decay` decimal(8,3) NULL DEFAULT NULL COMMENT '衰减度（每单位偏离扣分；NULL则用 preference.decay_default）',
  `min_score` decimal(8,3) NOT NULL DEFAULT 0.000 COMMENT '最低分（可设置为-0.5等）',
  `max_abs_delta` decimal(12,3) NULL DEFAULT NULL COMMENT '最大可接受偏差（超过则直接按min_score）',
  `enabled` bit(1) NOT NULL DEFAULT b'1' COMMENT '是否启用',

  `creator` varchar(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NULL DEFAULT '' COMMENT '创建者',
  `create_time` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  `updater` varchar(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NULL DEFAULT '' COMMENT '更新者',
  `update_time` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '更新时间',
  `deleted` bit(1) NOT NULL DEFAULT b'0' COMMENT '是否删除',
  `tenant_id` bigint NOT NULL DEFAULT 0 COMMENT '租户编号',

  PRIMARY KEY (`id`) USING BTREE,
  INDEX `idx_pref_enabled`(`preference_id` ASC, `enabled` ASC) USING BTREE,
  INDEX `idx_field_code`(`field_code` ASC) USING BTREE
) ENGINE = InnoDB
  CHARACTER SET = utf8mb4 COLLATE = utf8mb4_unicode_ci
  COMMENT = '达人-偏好数值赋分项';


-- 9) 标签加/减分项
DROP TABLE IF EXISTS `talent_preference_tag_score`;
CREATE TABLE `talent_preference_tag_score` (
  `id` bigint NOT NULL AUTO_INCREMENT COMMENT '主键',
  `preference_id` bigint NOT NULL COMMENT 'talent_preference.id',
  `tag_id` bigint NOT NULL COMMENT 'member_tag.id',
  `score` decimal(8,3) NOT NULL COMMENT '分值：如 喜欢+1，不喜欢-1，或自定义+4等',
  `enabled` bit(1) NOT NULL DEFAULT b'1' COMMENT '是否启用',

  `creator` varchar(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NULL DEFAULT '' COMMENT '创建者',
  `create_time` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  `updater` varchar(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NULL DEFAULT '' COMMENT '更新者',
  `update_time` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '更新时间',
  `deleted` bit(1) NOT NULL DEFAULT b'0' COMMENT '是否删除',
  `tenant_id` bigint NOT NULL DEFAULT 0 COMMENT '租户编号',

  PRIMARY KEY (`id`) USING BTREE,
  UNIQUE INDEX `uk_pref_tag`(`tenant_id` ASC, `preference_id` ASC, `tag_id` ASC, `deleted` ASC) USING BTREE,
  INDEX `idx_pref_enabled`(`preference_id` ASC, `enabled` ASC) USING BTREE
) ENGINE = InnoDB
  CHARACTER SET = utf8mb4 COLLATE = utf8mb4_unicode_ci
  COMMENT = '达人-偏好标签加减分';


-- 10) 匹配结果记录（可只存TopN）
DROP TABLE IF EXISTS `talent_match_record`;
CREATE TABLE `talent_match_record` (
  `id` bigint NOT NULL AUTO_INCREMENT COMMENT '匹配记录ID',
  `user_id` bigint NOT NULL COMMENT '客户 member_user.id',
  `preference_id` bigint NOT NULL COMMENT 'talent_preference.id',
  `provider_id` bigint NOT NULL COMMENT '命中的达人 talent_provider.id',
  `rank_no` int NOT NULL COMMENT '排序名次（1..N）',
  `total_score` decimal(10,3) NOT NULL COMMENT '总分',
  `filtered_reason` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT '若未入池/被过滤，可记录原因（可选）',
  `score_detail_json` json NULL DEFAULT NULL COMMENT '打分明细快照（各字段分/标签分/衰减参数等）',

  `creator` varchar(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NULL DEFAULT '' COMMENT '创建者',
  `create_time` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  `updater` varchar(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NULL DEFAULT '' COMMENT '更新者',
  `update_time` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '更新时间',
  `deleted` bit(1) NOT NULL DEFAULT b'0' COMMENT '是否删除',
  `tenant_id` bigint NOT NULL DEFAULT 0 COMMENT '租户编号',

  PRIMARY KEY (`id`) USING BTREE,
  INDEX `idx_user_time`(`user_id` ASC, `create_time` ASC) USING BTREE,
  INDEX `idx_pref`(`preference_id` ASC) USING BTREE,
  INDEX `idx_provider`(`provider_id` ASC) USING BTREE
) ENGINE = InnoDB
  CHARACTER SET = utf8mb4 COLLATE = utf8mb4_unicode_ci
  COMMENT = '达人-匹配结果记录';


-- =========================================================
-- 订单后“可疑字段校验/可信值”通用表（覆盖所有可能造假的自填字段）
-- 说明：数据库层无法判断“订单已完成”，需业务层校验订单状态。
-- =========================================================

-- 11) 可校验属性定义（登记哪些字段需要校验 + 用什么聚合算法）
DROP TABLE IF EXISTS `talent_verify_attribute`;
CREATE TABLE `talent_verify_attribute` (
  `id` bigint NOT NULL AUTO_INCREMENT COMMENT '主键',
  `code` varchar(32) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL COMMENT '属性编码（如 height_cm/weight_kg/city/work_years）',
  `name` varchar(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL COMMENT '属性名称',
  `value_type` tinyint NOT NULL COMMENT '值类型：10整数 20小数 30字符串 40枚举(字符串)',
  `agg_method` tinyint NOT NULL DEFAULT 20 COMMENT '聚合算法：10中位数 20去极值均值 30众数',
  `trim_ratio` decimal(5,4) NOT NULL DEFAULT 0.1250 COMMENT '去极值比例（0~0.5，例0.125表示去掉上下各12.5%）',
  `min_value_decimal` decimal(12,3) NULL DEFAULT NULL COMMENT '数值下限（可选）',
  `max_value_decimal` decimal(12,3) NULL DEFAULT NULL COMMENT '数值上限（可选）',
  `status` tinyint NOT NULL DEFAULT 0 COMMENT '状态：0启用 1停用',
  `remark` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT '备注',

  `creator` varchar(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NULL DEFAULT '' COMMENT '创建者',
  `create_time` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  `updater` varchar(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NULL DEFAULT '' COMMENT '更新者',
  `update_time` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '更新时间',
  `deleted` bit(1) NOT NULL DEFAULT b'0' COMMENT '是否删除',
  `tenant_id` bigint NOT NULL DEFAULT 0 COMMENT '租户编号',

  PRIMARY KEY (`id`) USING BTREE,
  UNIQUE INDEX `uk_tenant_code`(`tenant_id` ASC, `code` ASC, `deleted` ASC) USING BTREE,
  INDEX `idx_status`(`tenant_id` ASC, `status` ASC) USING BTREE
) ENGINE = InnoDB
  CHARACTER SET = utf8mb4 COLLATE = utf8mb4_unicode_ci
  COMMENT = '达人-可校验属性定义';


-- 12) 订单后反馈明细（必须是完成订单的客户；同一订单同一属性仅一次）
DROP TABLE IF EXISTS `talent_provider_verify_feedback`;
CREATE TABLE `talent_provider_verify_feedback` (
  `id` bigint NOT NULL AUTO_INCREMENT COMMENT '主键',
  `provider_id` bigint NOT NULL COMMENT '达人ID talent_provider.id',
  `attribute_code` varchar(32) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL COMMENT '属性编码（talent_verify_attribute.code）',
  `reporter_user_id` bigint NOT NULL COMMENT '反馈用户ID member_user.id',

  `trade_order_id` bigint NOT NULL COMMENT '交易订单编号（完成订单）',
  `trade_order_item_id` bigint NULL DEFAULT NULL COMMENT '交易订单项编号（可选，用于更强绑定）',

  `value_int` int NULL DEFAULT NULL COMMENT '反馈值-整数',
  `value_decimal` decimal(12,3) NULL DEFAULT NULL COMMENT '反馈值-小数',
  `value_str` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NULL DEFAULT NULL COMMENT '反馈值-字符串/枚举',
  `confidence` tinyint NOT NULL DEFAULT 3 COMMENT '置信度1~5（可选）',

  `audit_status` tinyint NOT NULL DEFAULT 10 COMMENT '审核：10待审 20通过 30驳回',
  `audit_reason` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT '驳回原因',
  `remark` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT '备注（可选）',

  `creator` varchar(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NULL DEFAULT '' COMMENT '创建者',
  `create_time` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  `updater` varchar(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NULL DEFAULT '' COMMENT '更新者',
  `update_time` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '更新时间',
  `deleted` bit(1) NOT NULL DEFAULT b'0' COMMENT '是否删除',
  `tenant_id` bigint NOT NULL DEFAULT 0 COMMENT '租户编号',

  PRIMARY KEY (`id`) USING BTREE,

  -- 防刷：同一订单、同一属性、同一达人、同一反馈人，只允许一条（未删除）
  UNIQUE INDEX `uk_once_per_order_attr`(
    `tenant_id` ASC, `provider_id` ASC, `attribute_code` ASC, `trade_order_id` ASC, `reporter_user_id` ASC, `deleted` ASC
  ) USING BTREE,

  INDEX `idx_provider_attr_audit`(`tenant_id` ASC, `provider_id` ASC, `attribute_code` ASC, `audit_status` ASC) USING BTREE,
  INDEX `idx_reporter_time`(`tenant_id` ASC, `reporter_user_id` ASC, `create_time` ASC) USING BTREE,
  INDEX `idx_order`(`tenant_id` ASC, `trade_order_id` ASC) USING BTREE
) ENGINE = InnoDB
  CHARACTER SET = utf8mb4 COLLATE = utf8mb4_unicode_ci
  COMMENT = '达人-可疑字段校验反馈（订单后）';


-- 13) 聚合后的可信值缓存（用于列表/搜索/排序，避免每次实时聚合）
DROP TABLE IF EXISTS `talent_provider_verify_stat`;
CREATE TABLE `talent_provider_verify_stat` (
  `id` bigint NOT NULL AUTO_INCREMENT COMMENT '主键',
  `provider_id` bigint NOT NULL COMMENT '达人ID talent_provider.id',
  `attribute_code` varchar(32) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL COMMENT '属性编码（talent_verify_attribute.code）',

  `verified_value_int` int NULL DEFAULT NULL COMMENT '可信值-整数',
  `verified_value_decimal` decimal(12,3) NULL DEFAULT NULL COMMENT '可信值-小数',
  `verified_value_str` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NULL DEFAULT NULL COMMENT '可信值-字符串/枚举',

  `sample_count` int NOT NULL DEFAULT 0 COMMENT '有效样本数（审核通过）',
  `min_value_decimal` decimal(12,3) NULL DEFAULT NULL COMMENT '最小值（数值类可选）',
  `max_value_decimal` decimal(12,3) NULL DEFAULT NULL COMMENT '最大值（数值类可选）',
  `method` tinyint NOT NULL DEFAULT 20 COMMENT '算法：10中位数 20去极值均值 30众数',
  `last_calc_time` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '最后计算时间',

  `creator` varchar(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NULL DEFAULT '' COMMENT '创建者',
  `create_time` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  `updater` varchar(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NULL DEFAULT '' COMMENT '更新者',
  `update_time` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '更新时间',
  `deleted` bit(1) NOT NULL DEFAULT b'0' COMMENT '是否删除',
  `tenant_id` bigint NOT NULL DEFAULT 0 COMMENT '租户编号',

  PRIMARY KEY (`id`) USING BTREE,
  UNIQUE INDEX `uk_provider_attr`(`tenant_id` ASC, `provider_id` ASC, `attribute_code` ASC, `deleted` ASC) USING BTREE,
  INDEX `idx_provider`(`tenant_id` ASC, `provider_id` ASC) USING BTREE,
  INDEX `idx_attr`(`tenant_id` ASC, `attribute_code` ASC) USING BTREE
) ENGINE = InnoDB
  CHARACTER SET = utf8mb4 COLLATE = utf8mb4_unicode_ci
  COMMENT = '达人-可疑字段可信值（聚合缓存）';

SET FOREIGN_KEY_CHECKS = 1;
