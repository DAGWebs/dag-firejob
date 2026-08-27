-- ESX stores job definitions in the database, so the three departments have to
-- exist here before anybody can be hired into one. QBCore and Qbox do NOT use
-- this file: their jobs live in shared/jobs.lua (see install/qb-core.md).
--
-- Grades match Config.Firefighter.ranks[].grade.

INSERT INTO `jobs` (`name`, `label`) VALUES
    ('lsfd', 'Los Santos Fire Department'),
    ('safd', 'San Andreas County Fire'),
    ('bcfd', 'Blaine County Fire and Rescue')
ON DUPLICATE KEY UPDATE `label` = VALUES(`label`);

INSERT INTO `job_grades` (`job_name`, `grade`, `name`, `label`, `salary`, `skin_male`, `skin_female`) VALUES
    ('lsfd', 0, 'probationary', 'Probationary', 500, '{}', '{}'),
    ('lsfd', 1, 'firefighter', 'Firefighter', 750, '{}', '{}'),
    ('lsfd', 2, 'engineer', 'Engineer', 900, '{}', '{}'),
    ('lsfd', 3, 'lieutenant', 'Lieutenant', 1100, '{}', '{}'),
    ('lsfd', 4, 'captain', 'Captain', 1400, '{}', '{}'),
    ('lsfd', 5, 'chief', 'Battalion Chief', 1800, '{}', '{}'),
    ('safd', 0, 'probationary', 'Probationary', 500, '{}', '{}'),
    ('safd', 1, 'firefighter', 'Firefighter', 750, '{}', '{}'),
    ('safd', 2, 'engineer', 'Engineer', 900, '{}', '{}'),
    ('safd', 3, 'lieutenant', 'Lieutenant', 1100, '{}', '{}'),
    ('safd', 4, 'captain', 'Captain', 1400, '{}', '{}'),
    ('safd', 5, 'chief', 'Battalion Chief', 1800, '{}', '{}'),
    ('bcfd', 0, 'probationary', 'Probationary', 500, '{}', '{}'),
    ('bcfd', 1, 'firefighter', 'Firefighter', 750, '{}', '{}'),
    ('bcfd', 2, 'engineer', 'Engineer', 900, '{}', '{}'),
    ('bcfd', 3, 'lieutenant', 'Lieutenant', 1100, '{}', '{}'),
    ('bcfd', 4, 'captain', 'Captain', 1400, '{}', '{}'),
    ('bcfd', 5, 'chief', 'Battalion Chief', 1800, '{}', '{}')
ON DUPLICATE KEY UPDATE `label` = VALUES(`label`);
