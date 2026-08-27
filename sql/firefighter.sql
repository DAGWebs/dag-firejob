-- Firefighter job schema.
--
-- Import this once, or leave Config.Firefighter.database.migrate = true and
-- the resource creates the same tables on first start. The table prefix must
-- match Config.Firefighter.database.prefix (default `firefighter_`).

CREATE TABLE IF NOT EXISTS `firefighter_profiles` (
    `identifier` VARCHAR(64) NOT NULL,
    `name` VARCHAR(64) DEFAULT NULL,
    `department` VARCHAR(32) DEFAULT NULL,
    `xp` INT NOT NULL DEFAULT 0,
    `certifications` LONGTEXT DEFAULT NULL,
    `training` LONGTEXT DEFAULT NULL,
    `stats` LONGTEXT DEFAULT NULL,
    `hired_at` BIGINT DEFAULT NULL,
    `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`identifier`),
    KEY `idx_firefighter_profiles_department` (`department`),
    KEY `idx_firefighter_profiles_xp` (`xp`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Every hire, promotion, demotion and termination, so a department can show
-- who signed off on what.
CREATE TABLE IF NOT EXISTS `firefighter_employment` (
    `id` INT NOT NULL AUTO_INCREMENT,
    `identifier` VARCHAR(64) NOT NULL,
    `department` VARCHAR(32) NOT NULL,
    `job` VARCHAR(32) DEFAULT NULL,
    `grade` INT NOT NULL DEFAULT 0,
    `rank` VARCHAR(32) DEFAULT NULL,
    `action` VARCHAR(16) NOT NULL,
    `actor` VARCHAR(64) DEFAULT NULL,
    `reason` VARCHAR(190) DEFAULT NULL,
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_firefighter_employment_identifier` (`identifier`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Academy results, pass or fail.
CREATE TABLE IF NOT EXISTS `firefighter_training` (
    `id` INT NOT NULL AUTO_INCREMENT,
    `identifier` VARCHAR(64) NOT NULL,
    `course` VARCHAR(32) NOT NULL,
    `certification` VARCHAR(32) NOT NULL,
    `passed` TINYINT(1) NOT NULL DEFAULT 0,
    `score` INT DEFAULT NULL,
    `instructor` VARCHAR(64) DEFAULT NULL,
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_firefighter_training_identifier` (`identifier`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- One row per closed call, for run reports and department statistics.
CREATE TABLE IF NOT EXISTS `firefighter_calls` (
    `id` INT NOT NULL AUTO_INCREMENT,
    `call_ref` VARCHAR(16) NOT NULL,
    `department` VARCHAR(32) DEFAULT NULL,
    `kind` VARCHAR(32) NOT NULL,
    `location` VARCHAR(190) DEFAULT NULL,
    `priority` TINYINT NOT NULL DEFAULT 3,
    `source` VARCHAR(24) DEFAULT NULL,
    `response_time` INT DEFAULT NULL,
    `duration` INT DEFAULT NULL,
    `extinguished` INT NOT NULL DEFAULT 0,
    `rescued` INT NOT NULL DEFAULT 0,
    `lost` INT NOT NULL DEFAULT 0,
    `payout` INT NOT NULL DEFAULT 0,
    `responders` LONGTEXT DEFAULT NULL,
    `outcome` VARCHAR(64) DEFAULT NULL,
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_firefighter_calls_department` (`department`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
