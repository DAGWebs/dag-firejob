-- ESX keeps items in the database. Servers running ox_inventory alongside ESX
-- should use install/ox_inventory.md instead of this file.

INSERT INTO `items` (`name`, `label`, `weight`, `rare`, `can_remove`) VALUES
    ('fire_extinguisher', 'Fire extinguisher', 4000, 0, 1),
    ('fire_hose', 'Hose line', 6000, 0, 1),
    ('scba_tank', 'SCBA cylinder', 7000, 0, 1),
    ('jaws_of_life', 'Jaws of life', 9000, 0, 1),
    ('halligan_bar', 'Halligan bar', 3000, 0, 1),
    ('fd_medbag', 'Medical bag', 5000, 0, 1),
    ('thermal_camera', 'Thermal imaging camera', 2000, 0, 1),
    ('hazmat_kit', 'Hazmat containment kit', 8000, 0, 1)
ON DUPLICATE KEY UPDATE `label` = VALUES(`label`);
