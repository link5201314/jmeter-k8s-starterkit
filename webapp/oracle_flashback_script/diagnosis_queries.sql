-- Oracle 闪回数据库诊断查询脚本

-- ========================================
-- 1. 检查闪回数据库是否启用
-- ========================================
-- 执行此查询确认闪回功能状态
SELECT flashback_on FROM v$database;

-- ========================================
-- 2. 检查恢复文件目标配置
-- ========================================
SELECT name, value FROM v$parameter 
WHERE name IN ('db_recovery_file_dest', 'db_recovery_file_dest_size')
ORDER BY name;

-- ========================================
-- 3. 检查恢复区域空间（关键指标）
-- ========================================
SELECT 
    name,
    ROUND(space_limit / 1024 / 1024 / 1024, 2) as space_limit_gb,
    ROUND(space_used / 1024 / 1024 / 1024, 2) as space_used_gb,
    ROUND(space_reclaimable / 1024 / 1024 / 1024, 2) as space_reclaimable_gb,
    number_of_files,
    ROUND(percent_space_used, 2) as percent_used
FROM v$recovery_file_dest;

-- ========================================
-- 4. 查看所有还原点及其可用性
-- ========================================
SELECT 
    name,
    scn,
    to_char(time, 'YYYY-MM-DD HH24:MI:SS') as restore_point_time,
    con_id,
    con_name
FROM v$restore_point
ORDER BY time DESC;

-- ========================================
-- 5. 获取当前数据库SCN和时间
-- ========================================
-- 用于比较和验证还原点是否在可恢复范围内
SELECT 
    dbms_flashback.get_system_change_number() as current_scn,
    SYSDATE as current_time
FROM dual;

-- ========================================
-- 6. 检查闪回日志保留期设置
-- ========================================
SHOW PARAMETER db_flashback_retention_target;

-- ========================================
-- 7. 检查归档日志模式（必须启用）
-- ========================================
SELECT log_mode FROM v$database;

-- ========================================
-- 8. 查看闪回数据库日志的位置和状态
-- ========================================
SELECT 
    file_type,
    ROUND(SUM(BYTES) / 1024 / 1024, 2) as size_mb,
    COUNT(*) as file_count
FROM v$recovery_area_disk_quota
GROUP BY file_type
ORDER BY file_type;

-- ========================================
-- 9. 查看数据库重做日志状态
-- ========================================
SELECT 
    group#,
    status,
    type,
    ROUND(bytes / 1024 / 1024, 2) as size_mb
FROM v$log
ORDER BY group#;

-- ========================================
-- 10. 检查PDB的闪回状态
-- ========================================
-- 如果是多租户环境，检查所有PDB
SELECT 
    pdb_name,
    open_cursors,
    status
FROM v$pdbs
ORDER BY pdb_name;

-- ========================================
-- 故障诊断步骤
-- ========================================
-- 步骤1：执行查询 1-3 来诊断基本配置
-- 步骤2：执行查询 4 来检查还原点是否存在
-- 步骤3：执行查询 5 来验证还原点是否在可恢复范围
-- 步骤4：如果还原失败，执行查询 6-7 来检查设置

-- ========================================
-- 解决 ORA-38729 的推荐步骤
-- ========================================

-- 步骤1：增加恢复文件目标大小（如果磁盘空间充足）
-- ALTER SYSTEM SET db_recovery_file_dest_size=500G SCOPE=BOTH;

-- 步骤2：清理旧的归档日志（在RMAN中执行）
-- RMAN> DELETE NOPROMPT ARCHIVELOG ALL;

-- 步骤3：增加闪回保留期
-- ALTER SYSTEM SET db_flashback_retention_target=2880 SCOPE=BOTH;

-- 步骤4：创建新的还原点（替换过期的）
-- ALTER PLUGGABLE DATABASE MVDIS_ST OPEN;
-- CREATE RESTORE POINT INIT_20260521 GUARANTEE FLASHBACK DATABASE;
