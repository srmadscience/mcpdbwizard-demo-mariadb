-- mcp_db_demo_user.sql: the database and login the hotel demo belongs to. Run it once, as root or
-- another account that can create databases and users:
--
--   mariadb -h <host> -u root -p < db/mcp_db_demo_user.sql
--
-- It creates the database mcpdemo and a login mcpdemo (password mcpdemo: change it for anything but
-- a demo) that owns it. The DDL then creates the demo's objects as mcpdemo, so its routines run with
-- mcpdemo's rights, and mcp_db_demo_drop.sql can remove them again.
--
-- The demo is simplest with MCPDBWizard logging in as mcpdemo too. For a login of its own instead,
-- grant it SELECT, EXECUTE and SHOW CREATE ROUTINE on mcpdemo.*, and INSERT on the two sequences:
-- see https://mcpdbwizard.com/docs/connecting-to-mariadb/#login.
--
-- If the server has binary logging on, creating the demo's function as a non-SUPER login also needs
-- SET GLOBAL log_bin_trust_function_creators = 1 (or run the DDL as root).

CREATE DATABASE mcpdemo CHARACTER SET utf8mb4;
CREATE USER 'mcpdemo'@'%' IDENTIFIED BY 'mcpdemo';
GRANT ALL ON mcpdemo.* TO 'mcpdemo'@'%';
