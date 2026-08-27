-- Firefighter job configuration.
--
-- Everything needed to re-theme the job for another server lives here:
-- departments, stations, apparatus, the run card, ranks, training, uniforms,
-- pay, and the simulation tuning constants. No coordinate or balance number
-- belongs in a module.
--
-- Coordinates are stock GTA V locations and are close enough to run on, but
-- treat them as a starting point rather than as surveyed values.

local resource = GetCurrentResourceName()

Config.Firefighter = {
    enabled = true,

    -- In-game configuration -----------------------------------------------
    -- Stations, departments, incident locations, and any setting addressed by
    -- a dotted path can be edited from in game by an admin and are stored as
    -- an override document over this file. `/set fslist` prints what is there.
    --
    -- `set` is a short, generic command name: change it if another resource on
    -- your server already owns it.
    editor = {
        enabled = true
        -- The command is `commands.editor` above.
    },

    -- Certifications gate apparatus, extrication, treatment, and containment.
    -- Turn this off for a server that would rather let anyone do anything and
    -- keep the ranks purely cosmetic.
    enforceCertifications = true,

    -- Commands and keys ------------------------------------------------------
    -- Every command this job registers and every key it binds is named here.
    -- The defaults are prefixed with the resource name so nothing collides on
    -- a busy server; shorten `commandPrefix` to 'fd' for /fd:duty, or give any
    -- single command a name of its own. Set one to false and it is not
    -- registered at all.
    commandPrefix = resource,

    commands = {
        -- Firefighters
        duty = resource .. ':duty',
        roster = resource .. ':roster',
        menu = resource .. ':fdmenu',
        hose = resource .. ':fdhose',
        mdt = resource .. ':mdt',
        -- Anyone
        emergency = resource .. ':911',
        report = resource .. ':fd911',
        -- Officers
        hire = resource .. ':fdhire',
        dismiss = resource .. ':fdfire',
        rank = resource .. ':fdrank',
        certify = resource .. ':fdcert',
        clear = resource .. ':fdclear',
        -- Administration
        dispatch = resource .. ':fdcall',
        experience = resource .. ':fdxp',
        editor = 'set'
    },

    -- Key bindings, as FiveM key names ('F6', 'HOME', 'NUMPAD5'). Set one to
    -- false to register the command without a key, which is what to do when
    -- something else on your server already owns it. Players can always
    -- rebind these under Settings, Key Bindings, FiveM.
    keybinds = {
        menu = 'F6',
        mdt = false,
        hose = false
    },

    -- Sent to Bridge.SetDuty when clocking on/off. Frameworks that do not
    -- implement duty simply report it as unsupported.
    syncFrameworkDuty = true,

    -- Persistence ----------------------------------------------------------
    -- 'auto' uses a SQL driver when one is running and falls back to the
    -- resource-owned JSON store when none is. Import sql/firefighter.sql, or
    -- leave `migrate` on and the tables are created on first start.
    database = {
        enabled = 'auto',   -- auto, true, false
        driver = 'auto',    -- auto, oxmysql, mysql-async, ghmattimysql
        migrate = true,
        prefix = 'firefighter_',
        -- Profiles are cached in memory and written behind; this is how often
        -- dirty profiles are flushed.
        flushInterval = 20000,
        logCalls = true
    },

    -- Authorization -------------------------------------------------------
    -- Duty and command are checked per department: a firefighter has to hold
    -- that department's framework job, or the matching ACE. The ACE names are
    -- <namespace>.<department>.<action>, so on a framework that cannot report
    -- jobs (standalone included) this is what makes the job usable:
    --
    --   add_ace group.admin dag-firejob.lsfd.duty allow
    --   add_ace group.admin dag-firejob.lsfd.command allow
    --   add_ace group.admin dag-firejob.admin allow
    access = {
        aceNamespace = resource,
        duty = { minimumGrade = 0 },
        command = { minimumGrade = 3 },
        admin = { ace = resource .. '.admin' }
    },

    -- Inventory -----------------------------------------------------------
    -- 'auto' enforces items only when the active framework can actually
    -- report an inventory, so standalone and item-less servers still work.
    -- Item definitions for every supported framework are in install/items/.
    items = {
        enforce = 'auto',   -- auto, true, false
        extinguisher = 'fire_extinguisher',
        hose = 'fire_hose',
        scba = 'scba_tank',
        jaws = 'jaws_of_life',
        halligan = 'halligan_bar',
        medbag = 'fd_medbag',
        thermal = 'thermal_camera',
        hazmat = 'hazmat_kit',
        -- Handed out at the locker when clocking on, taken back on clock-off.
        issued = { 'fire_extinguisher', 'scba_tank', 'halligan_bar' }
    },

    -- Departments ----------------------------------------------------------
    -- Each department owns its stations, its framework job, and its uniform.
    -- Calls are routed to whichever department's jurisdiction they fall in;
    -- `mutualAid` lists the departments that are toned out with it when it has
    -- nobody on duty.
    departments = {
        {
            id = 'lsfd',
            label = 'Los Santos Fire Department',
            short = 'LSFD',
            job = 'lsfd',
            stations = { 'davis', 'rockford' },
            jurisdiction = { center = vector3(213.0, -900.0, 30.0), radius = 3400.0 },
            mutualAid = { 'bcfd' },
            colour = 49,
            uniform = 'city'
        },
        {
            id = 'safd',
            label = 'San Andreas County Fire',
            short = 'SAFD',
            job = 'safd',
            stations = { 'sandy' },
            jurisdiction = { center = vector3(1900.0, 3700.0, 32.0), radius = 4200.0 },
            mutualAid = { 'bcfd', 'lsfd' },
            colour = 5,
            uniform = 'county'
        },
        {
            id = 'bcfd',
            label = 'Blaine County Fire and Rescue',
            short = 'BCFD',
            job = 'bcfd',
            stations = { 'paleto' },
            jurisdiction = { center = vector3(-380.0, 6100.0, 31.0), radius = 3600.0 },
            mutualAid = { 'safd' },
            colour = 46,
            uniform = 'county'
        }
    },

    -- Anything outside every jurisdiction radius goes to the department whose
    -- nearest station is closest.
    fallbackDepartment = 'lsfd',

    stations = {
        {
            id = 'davis',
            department = 'lsfd',
            label = 'Station 7 - Davis',
            coords = vector3(1193.54, -1473.65, 34.86),
            duty = vector3(1204.51, -1470.09, 34.86),
            locker = vector3(1197.15, -1462.66, 34.86),
            supply = vector3(1189.98, -1458.32, 34.86),
            garage = vector3(1207.51, -1444.31, 34.75),
            office = vector3(1200.13, -1467.11, 34.86),
            spawn = { coords = vector3(1213.44, -1451.61, 34.75), heading = 180.0 },
            ret = vector3(1213.44, -1451.61, 34.75),
            blip = { sprite = 436, colour = 49, scale = 0.8 }
        },
        {
            id = 'rockford',
            department = 'lsfd',
            label = 'Station 2 - Rockford Hills',
            coords = vector3(-627.51, -125.59, 38.75),
            duty = vector3(-618.75, -128.61, 38.75),
            locker = vector3(-625.44, -120.71, 38.75),
            supply = vector3(-632.10, -117.14, 38.75),
            garage = vector3(-611.26, -108.31, 38.20),
            office = vector3(-622.05, -123.44, 38.75),
            spawn = { coords = vector3(-606.51, -113.42, 38.20), heading = 118.0 },
            ret = vector3(-606.51, -113.42, 38.20),
            blip = { sprite = 436, colour = 49, scale = 0.8 }
        },
        {
            id = 'sandy',
            department = 'safd',
            label = 'Station 24 - Sandy Shores',
            coords = vector3(1691.06, 3584.41, 35.62),
            duty = vector3(1699.28, 3583.13, 35.62),
            locker = vector3(1693.71, 3589.85, 35.62),
            supply = vector3(1687.02, 3592.44, 35.62),
            garage = vector3(1684.11, 3604.83, 35.10),
            office = vector3(1696.44, 3587.19, 35.62),
            spawn = { coords = vector3(1690.09, 3603.16, 35.10), heading = 208.0 },
            ret = vector3(1690.09, 3603.16, 35.10),
            blip = { sprite = 436, colour = 5, scale = 0.7 }
        },
        {
            id = 'paleto',
            department = 'bcfd',
            label = 'Station 31 - Paleto Bay',
            coords = vector3(-379.35, 6118.53, 31.48),
            duty = vector3(-372.61, 6118.11, 31.48),
            locker = vector3(-383.29, 6122.16, 31.48),
            supply = vector3(-389.06, 6114.72, 31.48),
            garage = vector3(-364.42, 6124.55, 31.00),
            office = vector3(-377.11, 6121.05, 31.48),
            spawn = { coords = vector3(-358.75, 6127.19, 31.00), heading = 226.0 },
            ret = vector3(-358.75, 6127.19, 31.00),
            blip = { sprite = 436, colour = 46, scale = 0.7 }
        }
    },

    -- Uniforms -------------------------------------------------------------
    -- Component and prop indices, applied natively so this works without any
    -- clothing resource. `Config.Firefighter.uniforms.provider` can hand the
    -- job over to an appearance resource instead; the civilian outfit is
    -- always cached before a change and restored on clock-off.
    uniforms = {
        provider = 'auto',   -- auto, native, none
        sets = {
            city = {
                male = {
                    turnout = {
                        components = {
                            [3] = { 1, 0 }, [4] = { 30, 0 }, [6] = { 25, 0 },
                            [8] = { 15, 0 }, [11] = { 51, 0 }
                        },
                        props = { [0] = { 124, 0 } }
                    },
                    station = {
                        components = {
                            [3] = { 0, 0 }, [4] = { 35, 0 }, [6] = { 25, 0 },
                            [8] = { 15, 0 }, [11] = { 52, 0 }
                        },
                        props = {}
                    }
                },
                female = {
                    turnout = {
                        components = {
                            [3] = { 5, 0 }, [4] = { 36, 0 }, [6] = { 25, 0 },
                            [8] = { 14, 0 }, [11] = { 56, 0 }
                        },
                        props = { [0] = { 123, 0 } }
                    },
                    station = {
                        components = {
                            [3] = { 0, 0 }, [4] = { 34, 0 }, [6] = { 25, 0 },
                            [8] = { 14, 0 }, [11] = { 57, 0 }
                        },
                        props = {}
                    }
                }
            },
            county = {
                male = {
                    turnout = {
                        components = {
                            [3] = { 1, 0 }, [4] = { 30, 1 }, [6] = { 25, 0 },
                            [8] = { 15, 0 }, [11] = { 51, 1 }
                        },
                        props = { [0] = { 124, 1 } }
                    },
                    station = {
                        components = { [3] = { 0, 0 }, [4] = { 35, 1 }, [8] = { 15, 0 }, [11] = { 52, 1 } },
                        props = {}
                    }
                },
                female = {
                    turnout = {
                        components = {
                            [3] = { 5, 0 }, [4] = { 36, 1 }, [6] = { 25, 0 },
                            [8] = { 14, 0 }, [11] = { 56, 1 }
                        },
                        props = { [0] = { 123, 1 } }
                    },
                    station = {
                        components = { [3] = { 0, 0 }, [4] = { 34, 1 }, [8] = { 14, 0 }, [11] = { 57, 1 } },
                        props = {}
                    }
                }
            }
        }
    },

    -- Apparatus ------------------------------------------------------------
    apparatus = {
        {
            id = 'engine',
            label = 'Type 1 Engine',
            model = 'firetruk',
            water = 4000,
            certification = 'engine',
            description = 'Pumper with a 4,000 litre tank and a full hose bed.'
        },
        {
            id = 'ladder',
            label = 'Aerial Ladder',
            model = 'firetruk',
            water = 2800,
            certification = 'ladder',
            description = 'Aerial platform for high-rise and roof operations.'
        },
        {
            id = 'rescue',
            label = 'Heavy Rescue',
            model = 'lguard',
            water = 900,
            certification = 'rescue',
            carries = { 'jaws_of_life', 'halligan_bar' },
            description = 'Extrication tooling. Carries a light water supply.'
        },
        {
            id = 'brush',
            label = 'Brush Unit',
            model = 'sandking',
            water = 1600,
            description = 'Off-road unit for wildland and vegetation fires.'
        },
        {
            id = 'medic',
            label = 'Medic Unit',
            model = 'ambulance',
            water = 0,
            certification = 'ems',
            carries = { 'fd_medbag' },
            description = 'Patient treatment and transport. No pump.'
        },
        {
            id = 'battalion',
            label = 'Battalion Command',
            model = 'fbi2',
            water = 0,
            certification = 'command',
            description = 'Incident command vehicle.'
        }
    },

    -- Run card -------------------------------------------------------------
    -- `weight` is how often the ambient dispatcher draws this type. Medicals
    -- dominate a real run card, and they dominate this one.
    callTypes = {
        {
            id = 'medical',
            label = 'Medical emergency',
            priority = 1,
            weight = 10,
            blip = { sprite = 153, colour = 1 },
            fires = { min = 0, max = 0 },
            victims = { chance = 1.0, min = 1, max = 2 },
            spread = false,
            requiredCertification = 'ems',
            payout = 450,
            xp = 120,
            radius = 6.0,
            units = { 'medic' },
            locations = {
                { coords = vector3(-1305.44, -394.11, 36.70), label = 'Del Perro Beach boardwalk' },
                { coords = vector3(178.05, -1005.31, 29.30), label = 'Legion Square' },
                { coords = vector3(-262.11, -2023.44, 30.15), label = 'Chamberlain Hills' },
                { coords = vector3(1961.05, 3741.19, 32.34), label = 'Yellow Jack Inn' },
                { coords = vector3(-104.44, 6463.11, 31.46), label = 'Paleto Bay market' },
                { coords = vector3(-1150.19, -1521.05, 10.63), label = 'Vespucci Beach' }
            }
        },
        {
            id = 'mva',
            label = 'Traffic collision',
            priority = 1,
            weight = 8,
            blip = { sprite = 380, colour = 47 },
            fires = { min = 0, max = 2, intensity = { min = 25, max = 55 } },
            victims = { chance = 1.0, min = 1, max = 3, trapped = true },
            wrecks = { min = 1, max = 2, models = { 'sultan', 'asea', 'premier', 'bison' } },
            spread = false,
            requiredCertification = 'rescue',
            extrication = true,
            payout = 850,
            xp = 210,
            radius = 8.0,
            units = { 'rescue', 'medic' },
            locations = {
                { coords = vector3(-1329.44, -684.11, 25.32), label = 'Del Perro off-ramp' },
                { coords = vector3(64.31, 116.55, 79.19), label = 'Vinewood Blvd junction' },
                { coords = vector3(2452.05, 4111.44, 38.09), label = 'Route 68 bend' },
                { coords = vector3(96.11, 6435.31, 31.39), label = 'Great Ocean Hwy' },
                { coords = vector3(1207.44, -1560.19, 34.68), label = 'Davis Ave and Innocence' },
                { coords = vector3(1687.05, 4823.44, 42.01), label = 'Grapeseed crossroads' }
            }
        },
        {
            id = 'structure',
            label = 'Structure fire',
            priority = 1,
            weight = 6,
            blip = { sprite = 436, colour = 1 },
            fires = { min = 4, max = 8, intensity = { min = 55, max = 90 } },
            victims = { chance = 0.65, min = 1, max = 3 },
            spread = true,
            payout = 900,
            xp = 220,
            radius = 9.0,
            units = { 'engine', 'ladder' },
            locations = {
                { coords = vector3(-14.35, -1441.66, 31.10), label = 'Grove Street apartments' },
                { coords = vector3(1273.34, -1710.55, 54.77), label = 'El Burro Heights bungalow' },
                { coords = vector3(-1148.19, -1518.75, 10.63), label = 'Vespucci Beach condo' },
                { coords = vector3(340.02, -206.61, 54.08), label = 'Mirror Park duplex' },
                { coords = vector3(1972.44, 3815.71, 33.43), label = 'Sandy Shores trailer' },
                { coords = vector3(-278.31, 6229.44, 31.49), label = 'Paleto Bay storefront' }
            }
        },
        {
            id = 'vehicle',
            label = 'Vehicle fire',
            priority = 2,
            weight = 6,
            blip = { sprite = 436, colour = 47 },
            fires = { min = 2, max = 4, intensity = { min = 40, max = 70 } },
            victims = { chance = 0.35, min = 1, max = 1 },
            spread = false,
            payout = 450,
            xp = 90,
            radius = 4.0,
            units = { 'engine' },
            locations = {
                { coords = vector3(-206.51, -1339.44, 30.89), label = 'Innocence Blvd' },
                { coords = vector3(812.44, -1109.72, 26.36), label = 'Popular St underpass' },
                { coords = vector3(-1601.35, -1023.19, 13.02), label = 'Del Perro Fwy shoulder' },
                { coords = vector3(2570.11, 385.52, 108.62), label = 'Palomino Fwy' },
                { coords = vector3(1707.88, 4920.44, 42.07), label = 'Grapeseed Main St' }
            }
        },
        {
            id = 'alarm',
            label = 'Automatic fire alarm',
            priority = 3,
            weight = 5,
            blip = { sprite = 436, colour = 2 },
            fires = { min = 0, max = 2, intensity = { min = 20, max = 45 } },
            victims = { chance = 0.05, min = 1, max = 1 },
            spread = false,
            -- A quiet call: often nothing is burning, and it still pays a
            -- turnout so the roster is not punished for answering it.
            payout = 250,
            xp = 60,
            radius = 8.0,
            units = { 'engine' },
            locations = {
                { coords = vector3(-1379.11, -476.44, 32.22), label = 'Del Perro Plaza' },
                { coords = vector3(-717.05, -915.31, 19.21), label = 'Alta St offices' },
                { coords = vector3(238.44, 224.11, 106.28), label = 'Mirror Park Blvd retail' }
            }
        },
        {
            id = 'brush',
            label = 'Brush fire',
            priority = 3,
            weight = 4,
            blip = { sprite = 436, colour = 46 },
            fires = { min = 5, max = 10, intensity = { min = 30, max = 60 } },
            victims = { chance = 0.1, min = 1, max = 1 },
            spread = true,
            payout = 600,
            xp = 140,
            radius = 16.0,
            units = { 'brush' },
            locations = {
                { coords = vector3(-1516.44, 4989.11, 62.61), label = 'Mount Chiliad slope' },
                { coords = vector3(2216.05, 5605.73, 53.75), label = 'Grapeseed treeline' },
                { coords = vector3(-338.71, 4837.02, 148.15), label = 'Raton Canyon' },
                { coords = vector3(1339.55, 2661.19, 47.24), label = 'Route 68 scrub' }
            }
        },
        {
            id = 'gasleak',
            label = 'Gas leak',
            priority = 2,
            weight = 4,
            blip = { sprite = 436, colour = 5 },
            fires = { min = 0, max = 1, intensity = { min = 20, max = 35 } },
            victims = { chance = 0.3, min = 1, max = 2 },
            hazards = { chance = 1.0, min = 1, max = 2 },
            spread = false,
            requiredCertification = 'hazmat',
            payout = 750,
            xp = 190,
            radius = 9.0,
            units = { 'engine', 'rescue' },
            locations = {
                { coords = vector3(266.44, -1261.05, 29.29), label = 'Innocence Blvd service station' },
                { coords = vector3(-70.31, 6420.11, 31.49), label = 'Paleto Bay gas station' },
                { coords = vector3(1207.05, 2660.44, 37.90), label = 'Route 68 pumps' }
            }
        },
        {
            id = 'industrial',
            label = 'Industrial fire',
            priority = 1,
            weight = 3,
            blip = { sprite = 436, colour = 6 },
            fires = { min = 6, max = 11, intensity = { min = 65, max = 100 } },
            victims = { chance = 0.5, min = 1, max = 2 },
            hazards = { chance = 0.6, min = 1, max = 2 },
            spread = true,
            payout = 1400,
            xp = 320,
            radius = 12.0,
            units = { 'engine', 'ladder', 'rescue' },
            locations = {
                { coords = vector3(1201.44, -3116.55, 5.54), label = 'Elysian Island warehouse' },
                { coords = vector3(2748.19, 1466.31, 24.50), label = 'RON refinery' },
                { coords = vector3(-449.05, -1687.44, 18.99), label = 'La Puerta docks' },
                { coords = vector3(853.11, -3204.66, 5.90), label = 'Terminal storage yard' }
            }
        },
        {
            id = 'hazmat',
            label = 'Hazardous material spill',
            priority = 1,
            weight = 3,
            blip = { sprite = 436, colour = 5 },
            fires = { min = 0, max = 2, intensity = { min = 25, max = 45 } },
            victims = { chance = 0.45, min = 1, max = 2 },
            hazards = { chance = 1.0, min = 2, max = 4 },
            spread = false,
            requiredCertification = 'hazmat',
            payout = 1200,
            xp = 280,
            radius = 10.0,
            units = { 'rescue', 'battalion' },
            locations = {
                { coords = vector3(2678.44, 1671.05, 24.50), label = 'RON tanker rollover' },
                { coords = vector3(-1076.31, -1265.44, 5.55), label = 'Vespucci canals outfall' },
                { coords = vector3(1699.44, 3277.11, 41.09), label = 'Sandy Shores rail siding' }
            }
        },
        {
            id = 'elevator',
            label = 'Elevator rescue',
            priority = 3,
            weight = 3,
            blip = { sprite = 380, colour = 3 },
            fires = { min = 0, max = 0 },
            victims = { chance = 1.0, min = 1, max = 2, trapped = true },
            spread = false,
            requiredCertification = 'rescue',
            payout = 500,
            xp = 130,
            radius = 5.0,
            units = { 'rescue' },
            locations = {
                { coords = vector3(-75.11, -826.44, 243.38), label = 'Maze Bank Tower' },
                { coords = vector3(-141.05, -620.31, 168.82), label = 'Arcadius Business Centre' },
                { coords = vector3(1204.44, -3115.05, 5.54), label = 'Dock warehouse lift' }
            }
        },
        {
            id = 'water',
            label = 'Water rescue',
            priority = 1,
            weight = 2,
            blip = { sprite = 404, colour = 3 },
            fires = { min = 0, max = 0 },
            victims = { chance = 1.0, min = 1, max = 2 },
            spread = false,
            requiredCertification = 'rescue',
            payout = 950,
            xp = 240,
            radius = 12.0,
            units = { 'rescue', 'medic' },
            locations = {
                { coords = vector3(-1850.44, -1245.11, 8.61), label = 'Del Perro Pier' },
                { coords = vector3(-1024.05, -1387.31, 5.03), label = 'Vespucci Beach surf' },
                { coords = vector3(1310.44, 4225.05, 33.91), label = 'Alamo Sea shore' }
            }
        },
        {
            id = 'wires',
            label = 'Wires down',
            priority = 2,
            weight = 2,
            blip = { sprite = 436, colour = 5 },
            fires = { min = 1, max = 2, intensity = { min = 20, max = 40 } },
            victims = { chance = 0.15, min = 1, max = 1 },
            hazards = { chance = 1.0, min = 1, max = 1 },
            spread = false,
            payout = 500,
            xp = 120,
            radius = 7.0,
            units = { 'engine' },
            locations = {
                { coords = vector3(2337.05, 2571.44, 46.68), label = 'Route 68 power line' },
                { coords = vector3(-576.31, 5324.11, 70.22), label = 'Mount Chiliad pylon' },
                { coords = vector3(1109.44, -570.05, 56.72), label = 'Mirror Park transformer' }
            }
        }
    },

    -- Incident sources -----------------------------------------------------
    -- The ambient dispatcher keeps the department busy with NPC incidents when
    -- nothing player-driven is happening. The rest turn what players actually
    -- do into calls, so a fire on a player's car is the same call as one the
    -- dispatcher invented.
    events = {
        -- Ambient NPC incidents.
        ambient = { enabled = true },
        -- A player vehicle that catches fire is dispatched as a vehicle fire.
        vehicleFire = { enabled = true, kind = 'vehicle' },
        -- A heavy collision is dispatched as a traffic collision.
        collision = { enabled = true, kind = 'mva', minimumSpeed = 22.0, minimumDamage = 240.0 },
        -- Off by default: most servers already run an EMS job that owns this.
        playerDown = { enabled = false, kind = 'medical' },
        -- Any player can report an incident at their position.
        report = { enabled = true, kinds = { 'structure', 'vehicle', 'medical', 'mva', 'brush' } },
        -- A new call is not created within this distance of an open one; the
        -- open call is escalated instead.
        dedupeDistance = 45.0,
        -- Per player, across every automatic source.
        cooldown = 90000
    },

    dispatch = {
        -- Nobody on duty means no ambient calls; the city does not burn for an
        -- empty roster. Player-caused incidents are still dispatched and wait
        -- on the board.
        minimumOnDuty = 1,
        -- Concurrent open calls: this many, plus one per on-duty firefighter,
        -- up to the ceiling.
        maxActive = 2,
        perFirefighter = 1,
        maxActiveCeiling = 8,
        interval = { min = 180000, max = 420000 },
        -- An unanswered call gets worse before it gives up.
        escalateAfter = 240000,
        expireAfter = 1200000,
        -- How close a responder has to be for the call to count as worked, and
        -- for water/rescue actions to be accepted at all.
        onSceneDistance = 90.0,
        actionDistance = 12.0,
        -- Response bonus window, measured from dispatch to first arrival.
        responseWindow = 180000,
        -- Tone a call out to the whole city rather than one department.
        broadcastToAll = false,
        -- Bring in mutual aid when the owning department has nobody on duty.
        mutualAidAfter = 120000
    },

    fire = {
        tickInterval = 2000,
        -- Intensity a burning node gains per tick when nobody is on it.
        growth = 2.5,
        maxIntensity = 100,
        spreadThreshold = 70,
        spreadChance = 0.16,
        spreadRadius = 7.0,
        maxNodes = 16,
        -- A node below `residualHeat` is out of flame but still hot; leaving
        -- the scene early is how a call reignites.
        residualHeat = 18,
        reigniteChance = 0.1,
        -- Litres of water per point of intensity removed, before the agent
        -- multiplier below.
        litresPerPoint = 2.2,
        reportInterval = 400,
        maxLitresPerReport = 90,
        agents = {
            hose = { multiplier = 1.0, range = 14.0, flow = 65, item = 'fire_hose', needsLine = true },
            extinguisher = { multiplier = 0.55, range = 6.0, flow = 18, item = 'fire_extinguisher' },
            monitor = { multiplier = 1.6, range = 22.0, flow = 120, needsApparatus = true }
        },
        heat = {
            radius = 5.0,
            damage = 6,
            interval = 1500,
            -- Turnout gear and a charged SCBA cut incoming heat damage.
            gearMultiplier = 0.3
        }
    },

    -- Hose lines -----------------------------------------------------------
    -- A supply line runs hydrant to pump; an attack line runs pump to
    -- firefighter and is laid as props as they walk it out. Past
    -- `attackLength` from the pump the line is stretched and the nozzle stops.
    hose = {
        prop = 'prop_fire_hose',
        segment = 3.5,
        attackLength = 38.0,
        deployTime = 4000,
        -- A supply line makes the pump draw from the hydrant instead of the
        -- tank, so the tank stops going down.
        supplyLength = 14.0,
        supplyDeployTime = 6000
    },

    -- Extrication ----------------------------------------------------------
    -- Worked in order against the wreck the patient is trapped in. A stage
    -- that names an item needs that item in hand.
    extrication = {
        stages = {
            { id = 'stabilise', label = 'Stabilise the vehicle', time = 6000 },
            { id = 'glass', label = 'Take the glass out', time = 5000, item = 'halligan_bar' },
            { id = 'door', label = 'Force the door with the jaws', time = 9000, item = 'jaws_of_life' },
            { id = 'roof', label = 'Cut the roof away', time = 11000, item = 'jaws_of_life' },
            { id = 'remove', label = 'Remove the patient', time = 7000 }
        }
    },

    scba = {
        capacity = 1500,
        drain = 1,
        drainInSmoke = 4,
        smokeRadius = 8.0,
        warnAt = 300
    },

    water = {
        hydrantModels = {
            'prop_fire_hydrant_1',
            'prop_fire_hydrant_2',
            'prop_fire_hydrant_3',
            'prop_fire_hydrant_4'
        },
        hydrantDistance = 4.0,
        -- How far the pump panel reaches from the apparatus.
        apparatusDistance = 8.0,
        refillRate = 400,
        extinguisherCapacity = 220
    },

    victims = {
        -- Milliseconds of work to free a trapped patient and to treat one.
        extricationTime = 12000,
        treatmentTime = 8000,
        -- Condition lost per simulation tick while a patient waits, scaled by
        -- how bad the scene still is. A patient who reaches zero is lost: the
        -- turnout still pays, the rescue bonus does not.
        deterioration = { trapped = 3.0, freed = 1.5 },
        hospital = vector3(298.68, -584.44, 43.26),
        models = { 'a_m_y_business_01', 'a_f_y_tourist_01', 'a_m_m_farmer_01', 'a_f_m_soucent_01' }
    },

    hazards = {
        containmentTime = 15000,
        item = 'hazmat_kit'
    },

    -- Ranks ----------------------------------------------------------------
    -- `grade` is the framework job grade set when a firefighter is promoted to
    -- this rank, so it has to match the grades in your framework's job
    -- definition (install/jobs/).
    ranks = {
        { id = 'probationary', label = 'Probationary', grade = 0, xp = 0, pay = 0.85, certifications = {} },
        { id = 'firefighter', label = 'Firefighter', grade = 1, xp = 750, pay = 1.0, certifications = { 'engine' } },
        { id = 'engineer', label = 'Engineer', grade = 2, xp = 2500, pay = 1.15, certifications = { 'ladder' } },
        { id = 'lieutenant', label = 'Lieutenant', grade = 3, xp = 6000, pay = 1.3, certifications = {} },
        { id = 'captain', label = 'Captain', grade = 4, xp = 12000, pay = 1.5, certifications = {} },
        { id = 'chief', label = 'Battalion Chief', grade = 5, xp = 25000, pay = 1.75, certifications = { 'command' } }
    },

    certifications = {
        { id = 'engine', label = 'Pump operator', description = 'Drive and operate an engine.' },
        { id = 'ladder', label = 'Aerial operations', description = 'Operate the aerial ladder.' },
        { id = 'ems', label = 'Emergency medical', description = 'Treat and transport patients.' },
        { id = 'rescue', label = 'Technical rescue', description = 'Extrication and confined space.' },
        { id = 'hazmat', label = 'Hazardous materials', description = 'Contain chemical releases.' },
        { id = 'command', label = 'Incident command', description = 'Run the dispatch board.' }
    },

    -- Academy --------------------------------------------------------------
    -- Every certification can be earned by training rather than waiting for a
    -- rank, or signed off by an officer. A course is a classroom phase and,
    -- where it makes sense, a practical drill on a live training scene.
    academy = {
        enabled = true,
        label = 'San Andreas Fire Academy',
        coords = vector3(1183.44, -1463.11, 34.86),
        classroom = vector3(1188.05, -1466.31, 34.86),
        drill = vector3(1176.31, -1442.05, 34.86),
        blip = { sprite = 175, colour = 49, scale = 0.7 },
        -- How long a failed course locks the trainee out.
        retryDelay = 300000,
        courses = {
            {
                id = 'engine',
                certification = 'engine',
                label = 'Pump operations',
                description = 'Draft, charge a line, and put water on a training fire.',
                classroom = 30000,
                cost = 0,
                practical = { kind = 'suppression', targets = 3, timeLimit = 240000 }
            },
            {
                id = 'ems',
                certification = 'ems',
                label = 'Emergency medical technician',
                description = 'Assess and treat two patients inside the time limit.',
                classroom = 45000,
                cost = 250,
                practical = { kind = 'treatment', targets = 2, timeLimit = 240000 }
            },
            {
                id = 'ladder',
                certification = 'ladder',
                label = 'Aerial operations',
                description = 'Set up and work from the aerial platform.',
                classroom = 40000,
                cost = 250,
                requires = { 'engine' },
                practical = { kind = 'suppression', targets = 2, timeLimit = 180000 }
            },
            {
                id = 'rescue',
                certification = 'rescue',
                label = 'Technical rescue',
                description = 'Work a wreck from stabilisation to patient removal.',
                classroom = 45000,
                cost = 500,
                requires = { 'ems' },
                minimumRank = 1,
                practical = { kind = 'extrication', targets = 1, timeLimit = 300000 }
            },
            {
                id = 'hazmat',
                certification = 'hazmat',
                label = 'Hazardous materials technician',
                description = 'Identify and contain a chemical release.',
                classroom = 60000,
                cost = 500,
                requires = { 'engine' },
                minimumRank = 2,
                practical = { kind = 'containment', targets = 2, timeLimit = 240000 }
            },
            {
                id = 'command',
                certification = 'command',
                label = 'Incident command',
                description = 'Run a board, assign units, and close out a call.',
                classroom = 90000,
                cost = 1000,
                requires = { 'engine', 'ems' },
                minimumRank = 3
            }
        }
    },

    pay = {
        -- Where wages come from.
        --   government   an external budget: pay is created when it is earned,
        --                which is how most servers run a whitelisted job.
        --   department   the department's own account, funded by what it
        --                bills. A department that has not billed enough runs
        --                out of money and cannot pay its crews, which is the
        --                point of choosing it.
        funding = 'government',
        account = 'bank',
        -- Every responder is paid; the call payout is split between them so a
        -- full crew is not a pay cut but a solo run is not free money either.
        split = true,
        minimumShare = 0.35,
        perFire = 35,
        perVictim = 300,
        perHazard = 250,
        responseBonus = 200,
        cleanSceneBonus = 1.15
    },

    -- Billing ---------------------------------------------------------------
    -- The department keeps its own invoice ledger, because no two frameworks
    -- agree on what an invoice is. Settlement goes through the bridge's money
    -- methods, so it works on every framework; `provider` additionally mirrors
    -- the invoice into a billing resource when one is running.
    billing = {
        enabled = true,

        -- Who collects the money, which is the decision everything else hangs
        -- off:
        --   framework    the framework's billing resource owns the invoice end
        --                to end. It decides where the money goes, so the split
        --                below cannot apply.
        --   department   the department's ledger collects it, moving the money
        --                through the framework's own accounts. The split
        --                applies, and the department account is real.
        --   auto         framework when a billing resource is running and the
        --                whole invoice was going to the department anyway;
        --                otherwise department. The choice is printed at start.
        settlement = 'auto',

        provider = 'auto',   -- auto, internal, esx_billing, qb-phone, none
        account = 'bank',

        -- Where a paid invoice goes. Anything not named here goes to the
        -- department, so { author = 0.2 } is a 20/80 split with the
        -- firefighter who raised it. Shares are fractions of the invoice and
        -- must not add up to more than 1.
        --
        -- Only applies when the department is collecting: a framework billing
        -- resource pays itself, and cannot be asked to split.
        split = {
            author = 0.0,       -- the firefighter or medic who raised it
            crew = 0.0,         -- shared between whoever worked the call
            department = 1.0
        },
        -- A share for somebody who has logged off is kept by the department
        -- rather than vanishing.
        offlineSharesToDepartment = true,
        -- Where collected fees go. The internal balance is always authoritative;
        -- a society provider is mirrored into when one is available.
        society = {
            enabled = true,
            provider = 'auto',   -- auto, internal, qb-management, esx_addonaccount
            account = 'lsfd'     -- society name for the framework provider
        },
        -- What each thing is worth. An invoice raised from a call is built from
        -- what actually happened on it.
        fees = {
            response = 250,
            perFire = 75,
            perLitre = 0.4,
            ems = 400,
            transport = 600,
            extrication = 850,
            hazmat = 1200,
            falseAlarm = 300
        },
        -- Billing resources are integrated by event name rather than by a
        -- hard-coded call, so a fork that renamed one is retargeted here
        -- instead of in the module.
        providers = {
            esx_billing = { resource = 'esx_billing', event = 'esx_billing:sendBill', society = 'society_fire' },
            ['qb-phone'] = { resource = 'qb-phone', clientEvent = 'qb-phone:client:AddInvoice' }
        },
        tax = 0.0,
        -- A player whose own car burned or who wrapped it round a pole is a
        -- billable party the server actually knows about.
        autoBill = { playerCaused = true },
        -- Invoices older than this are hidden from the terminal's default view.
        historyDays = 30
    },

    -- Mobile data terminal ---------------------------------------------------
    mdt = {
        enabled = true,
        -- The command and key are in `commands` and `keybinds` above.
        -- Filing an incident report after a call is worth something, or nobody
        -- ever files one.
        reportBonus = { pay = 150, xp = 40 },
        pageSize = 10
    },

    -- Effects ----------------------------------------------------------------
    -- Particle, sound and screen effect names, all overridable: a server with
    -- a custom particle dictionary retargets it here rather than in code, and
    -- anything that fails to load is skipped rather than erroring.
    effects = {
        enabled = true,
        water = {
            asset = 'core',
            stream = 'ent_sht_water',
            steam = 'ent_amb_steam_ground',
            scale = 1.6
        },
        smoke = {
            asset = 'core',
            effect = 'ent_amb_smoke_foundry',
            -- The column a working fire puts up, visible from across the map.
            column = 'ent_ray_paleto_gate_smoke',
            columnAt = 0.45,        -- severity the column appears at
            columnScale = 6.0,
            scale = 2.5,
            -- How far into the smoke before it starts blinding.
            radius = 9.0,
            timecycle = 'smoke_flare',
            strength = 0.85
        },
        heat = { timecycle = 'heatwave', radius = 7.0 },
        -- Vision closing in as the cylinder empties, so the gauge is felt and
        -- not just read.
        air = {
            warnAt = 0.25,
            criticalAt = 0.1,
            timecycle = 'Dying01',
            breathing = { audioRef = 'SCUBA_SOUNDS', audioName = 'Breathing_Loop', interval = 3200 },
            heartbeat = { audioRef = 'MP_MISSION_COUNTDOWN_SOUNDSET', audioName = 'Woosh', interval = 900 }
        },
        sound = {
            enabled = true,
            fire = { audioRef = 'DLC_HEIST_HACKING_SNAKE_SOUNDS', audioName = 'Beep', interval = 4000 },
            dispatch = { audioRef = 'HUD_FRONTEND_DEFAULT_SOUNDSET', audioName = 'CHECKPOINT_PERFECT' },
            mayday = { audioRef = 'HUD_FRONTEND_DEFAULT_SOUNDSET', audioName = 'CHECKPOINT_MISSED' }
        },
        -- Scorch and smoke left behind after a structure fire closes.
        aftermath = {
            enabled = true,
            duration = 900000,
            effect = 'ent_amb_smoke_foundry',
            scale = 1.2
        }
    },

    -- Crew ---------------------------------------------------------------------
    -- Work goes faster the more hands are on it, always. Hard requirements are
    -- opt-in, because a two-firefighter server should still be able to play.
    crew = {
        enabled = true,
        -- Every extra pair of hands on the same job takes this much off the
        -- clock, down to the floor.
        assistBonus = 0.25,
        assistFloor = 0.5,
        -- Turn on to make the listed jobs actually need a second firefighter.
        enforce = false,
        requiresTwo = { 'roof', 'ladder', 'supply' },
        roles = {
            { id = 'command', label = 'Incident command', exclusive = true, certification = 'command' },
            { id = 'nozzle', label = 'Nozzle', exclusive = false },
            { id = 'backup', label = 'Backup line', exclusive = false },
            { id = 'pump', label = 'Pump operator', exclusive = true, certification = 'engine' },
            { id = 'search', label = 'Search and rescue', exclusive = false },
            { id = 'medic', label = 'Patient care', exclusive = false, certification = 'ems' }
        },
        -- Personnel accountability: command calls it, everybody answers.
        par = { window = 30000, cooldown = 60000 }
    },

    -- Mayday --------------------------------------------------------------------
    mayday = {
        enabled = true,
        -- A firefighter this hurt, or out of air in smoke, goes down.
        healthAt = 120,
        -- How long somebody has to reach them.
        window = 120000,
        -- Dragging them out.
        dragTime = 6000,
        dragDistance = 2.5,
        -- What reaching them in time is worth.
        reward = { pay = 750, xp = 200 }
    },

    -- Reading the fire -----------------------------------------------------------
    -- Both of these warn before they happen, and both are avoidable: knock the
    -- fire down, or get out.
    hazardEvents = {
        flashover = {
            enabled = true,
            kinds = { structure = true, industrial = true },
            -- Average node intensity the risk starts building at.
            threshold = 75,
            buildPerTick = 4,
            warnAt = 60,
            radius = 9.0,
            damage = 120
        },
        collapse = {
            enabled = true,
            kinds = { structure = true, industrial = true },
            -- How long a structure has to burn unchecked first.
            after = 420000,
            warning = 15000,
            radius = 12.0,
            damage = 150
        }
    },

    -- Triage ---------------------------------------------------------------------
    -- Working the worst patient first is what the bonus pays for.
    triage = {
        enabled = true,
        immediate = 35,   -- condition at or below this is red
        delayed = 65,     -- ...and below this is yellow
        orderBonus = 250,
        orderXp = 60
    },

    -- Skill --------------------------------------------------------------------
    -- A timed job can be finished early by working it well. The server still
    -- refuses anything faster than `floor` of the full time, so the best a
    -- client can do by lying is the same as the best a good player can do.
    skill = {
        enabled = true,
        floor = 0.55,
        provider = 'auto',   -- auto, ox_lib, bundled, none
        window = 0.28,       -- how wide the target zone is
        speed = 1.15,
        -- What finishing fast is worth, at most.
        bonus = { pay = 120, xp = 25 }
    },

    -- Station life ----------------------------------------------------------------
    -- The job is mostly waiting. These are what to do while waiting.
    chores = {
        enabled = true,
        cooldown = 1800000,
        list = {
            { id = 'apparatus', label = 'Apparatus check', point = 'garage', time = 12000, pay = 200, xp = 25 },
            { id = 'hose', label = 'Hose test', point = 'supply', time = 15000, pay = 250, xp = 30 },
            { id = 'inventory', label = 'Equipment inventory', point = 'locker', time = 10000, pay = 150, xp = 20 },
            { id = 'housework', label = 'Clean the station', point = 'office', time = 18000, pay = 175, xp = 20 }
        }
    },

    -- Scanner -----------------------------------------------------------------------
    -- Other services listening in. The event carries the call, and any resource
    -- can subscribe to it; naming one here also pushes it straight there.
    scanner = {
        enabled = true,
        -- Calls at or above this priority are put out on the wire.
        priority = 2,
        -- An event another dispatch resource listens on, or false for none.
        event = false
    },

    hud = {
        enabled = true,
        x = 0.015,
        y = 0.70
    }
}
