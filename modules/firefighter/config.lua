-- Firefighter job configuration.
--
-- Everything the job needs to be re-themed for another server lives here:
-- stations, apparatus, incident locations, ranks, pay, and the simulation
-- tuning constants. No coordinate or balance number belongs in the modules.
--
-- Coordinates are stock GTA V locations and are close enough to run on, but
-- treat them as a starting point rather than as surveyed values.

local resource = GetCurrentResourceName()

Config.Firefighter = {
    enabled = true,

    -- Who may clock in. Checked with DAG.Access, so a framework job, an ACE
    -- permission, or both can grant it. `jobs` maps a framework job name to the
    -- minimum grade; a framework that cannot report jobs is a denial, so the
    -- ACE entry is what makes the job usable on standalone:
    --   add_ace group.admin <resource>.fire.duty allow
    access = {
        duty = {
            jobs = { fire = 0, fireman = 0, lsfd = 0, firefighter = 0 },
            ace = resource .. '.fire.duty'
        },
        -- Officers: force a dispatch, reassign, clear a call, grant training.
        command = {
            jobs = { fire = 3, fireman = 3, lsfd = 3, firefighter = 3 },
            ace = resource .. '.fire.command'
        },
        -- Administration: spawn incidents anywhere, wipe state, award XP.
        admin = { ace = resource .. '.fire.admin' }
    },

    -- Prefix for the commands this job registers, so two resources built from
    -- the template never fight over a name. Set to 'fd' for /fd:duty.
    commandPrefix = resource,

    -- Sent to Bridge.SetDuty when clocking on/off. Frameworks that do not
    -- implement duty simply report it as unsupported.
    syncFrameworkDuty = true,

    -- Certifications gate apparatus, extrication, treatment, and containment.
    -- Turn this off for a server that would rather let anyone do anything and
    -- keep the ranks purely cosmetic.
    enforceCertifications = true,

    stations = {
        {
            id = 'davis',
            label = 'Station 7 - Davis',
            coords = vector3(1193.54, -1473.65, 34.86),
            duty = vector3(1204.51, -1470.09, 34.86),
            locker = vector3(1197.15, -1462.66, 34.86),
            supply = vector3(1189.98, -1458.32, 34.86),
            garage = vector3(1207.51, -1444.31, 34.75),
            spawn = { coords = vector3(1213.44, -1451.61, 34.75), heading = 180.0 },
            ret = vector3(1213.44, -1451.61, 34.75),
            blip = { sprite = 436, colour = 49, scale = 0.8 }
        },
        {
            id = 'rockford',
            label = 'Station 2 - Rockford Hills',
            coords = vector3(-627.51, -125.59, 38.75),
            duty = vector3(-618.75, -128.61, 38.75),
            locker = vector3(-625.44, -120.71, 38.75),
            supply = vector3(-632.10, -117.14, 38.75),
            garage = vector3(-611.26, -108.31, 38.20),
            spawn = { coords = vector3(-606.51, -113.42, 38.20), heading = 118.0 },
            ret = vector3(-606.51, -113.42, 38.20),
            blip = { sprite = 436, colour = 49, scale = 0.8 }
        },
        {
            id = 'sandy',
            label = 'Station 24 - Sandy Shores',
            coords = vector3(1691.06, 3584.41, 35.62),
            duty = vector3(1699.28, 3583.13, 35.62),
            locker = vector3(1693.71, 3589.85, 35.62),
            supply = vector3(1687.02, 3592.44, 35.62),
            garage = vector3(1684.11, 3604.83, 35.10),
            spawn = { coords = vector3(1690.09, 3603.16, 35.10), heading = 208.0 },
            ret = vector3(1690.09, 3603.16, 35.10),
            blip = { sprite = 436, colour = 49, scale = 0.7 }
        },
        {
            id = 'paleto',
            label = 'Station 31 - Paleto Bay',
            coords = vector3(-379.35, 6118.53, 31.48),
            duty = vector3(-372.61, 6118.11, 31.48),
            locker = vector3(-383.29, 6122.16, 31.48),
            supply = vector3(-389.06, 6114.72, 31.48),
            garage = vector3(-364.42, 6124.55, 31.00),
            spawn = { coords = vector3(-358.75, 6127.19, 31.00), heading = 226.0 },
            ret = vector3(-358.75, 6127.19, 31.00),
            blip = { sprite = 436, colour = 49, scale = 0.7 }
        }
    },

    -- Apparatus available from a station garage. `certification` and `rank`
    -- gate who may take one out; both are enforced on the server.
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
            description = 'Extrication tooling. Carries a light water supply.'
        },
        {
            id = 'brush',
            label = 'Brush Unit',
            model = 'sandking',
            water = 1600,
            certification = nil,
            description = 'Off-road unit for wildland and vegetation fires.'
        },
        {
            id = 'medic',
            label = 'Medic Unit',
            model = 'ambulance',
            water = 0,
            certification = 'ems',
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

    -- Incident catalogue. `locations` are candidates the dispatcher draws from;
    -- an officer or admin can also start one anywhere.
    callTypes = {
        {
            id = 'structure',
            label = 'Structure fire',
            priority = 1,
            blip = { sprite = 436, colour = 1 },
            fires = { min = 4, max = 8, intensity = { min = 55, max = 90 } },
            victims = { chance = 0.65, min = 1, max = 3 },
            spread = true,
            payout = 900,
            xp = 220,
            radius = 9.0,
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
            blip = { sprite = 436, colour = 47 },
            fires = { min = 2, max = 4, intensity = { min = 40, max = 70 } },
            victims = { chance = 0.35, min = 1, max = 1 },
            spread = false,
            payout = 450,
            xp = 90,
            radius = 4.0,
            locations = {
                { coords = vector3(-206.51, -1339.44, 30.89), label = 'Innocence Blvd' },
                { coords = vector3(812.44, -1109.72, 26.36), label = 'Popular St underpass' },
                { coords = vector3(-1601.35, -1023.19, 13.02), label = 'Del Perro Fwy shoulder' },
                { coords = vector3(2570.11, 385.52, 108.62), label = 'Palomino Fwy' },
                { coords = vector3(1707.88, 4920.44, 42.07), label = 'Grapeseed Main St' }
            }
        },
        {
            id = 'brush',
            label = 'Brush fire',
            priority = 3,
            blip = { sprite = 436, colour = 46 },
            fires = { min = 5, max = 10, intensity = { min = 30, max = 60 } },
            victims = { chance = 0.1, min = 1, max = 1 },
            spread = true,
            payout = 600,
            xp = 140,
            radius = 16.0,
            locations = {
                { coords = vector3(-1516.44, 4989.11, 62.61), label = 'Mount Chiliad slope' },
                { coords = vector3(2216.05, 5605.73, 53.75), label = 'Grapeseed treeline' },
                { coords = vector3(-338.71, 4837.02, 148.15), label = 'Raton Canyon' },
                { coords = vector3(1339.55, 2661.19, 47.24), label = 'Route 68 scrub' }
            }
        },
        {
            id = 'industrial',
            label = 'Industrial fire',
            priority = 1,
            blip = { sprite = 436, colour = 6 },
            fires = { min = 6, max = 11, intensity = { min = 65, max = 100 } },
            victims = { chance = 0.5, min = 1, max = 2 },
            hazards = { chance = 0.6, min = 1, max = 2 },
            spread = true,
            payout = 1400,
            xp = 320,
            radius = 12.0,
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
            blip = { sprite = 436, colour = 5 },
            fires = { min = 0, max = 2, intensity = { min = 25, max = 45 } },
            victims = { chance = 0.45, min = 1, max = 2 },
            hazards = { chance = 1.0, min = 2, max = 4 },
            spread = false,
            requiredCertification = 'hazmat',
            payout = 1200,
            xp = 280,
            radius = 10.0,
            locations = {
                { coords = vector3(2678.44, 1671.05, 24.50), label = 'RON tanker rollover' },
                { coords = vector3(-1076.31, -1265.44, 5.55), label = 'Vespucci canals outfall' },
                { coords = vector3(1699.44, 3277.11, 41.09), label = 'Sandy Shores rail siding' }
            }
        },
        {
            id = 'rescue',
            label = 'Vehicle extrication',
            priority = 2,
            blip = { sprite = 436, colour = 3 },
            fires = { min = 0, max = 1, intensity = { min = 20, max = 40 } },
            victims = { chance = 1.0, min = 1, max = 3, trapped = true },
            spread = false,
            requiredCertification = 'rescue',
            payout = 800,
            xp = 200,
            radius = 6.0,
            locations = {
                { coords = vector3(-1329.44, -684.11, 25.32), label = 'Del Perro off-ramp' },
                { coords = vector3(64.31, 116.55, 79.19), label = 'Vinewood Blvd junction' },
                { coords = vector3(2452.05, 4111.44, 38.09), label = 'Route 68 bend' },
                { coords = vector3(96.11, 6435.31, 31.39), label = 'Great Ocean Hwy' }
            }
        },
        {
            id = 'alarm',
            label = 'Automatic fire alarm',
            priority = 3,
            blip = { sprite = 436, colour = 2 },
            fires = { min = 0, max = 2, intensity = { min = 20, max = 45 } },
            victims = { chance = 0.05, min = 1, max = 1 },
            spread = false,
            -- A quiet call: often nothing is burning, and it still pays a
            -- turnout so the roster is not punished for answering it.
            payout = 250,
            xp = 60,
            radius = 8.0,
            locations = {
                { coords = vector3(-1379.11, -476.44, 32.22), label = 'Del Perro Plaza' },
                { coords = vector3(-717.05, -915.31, 19.21), label = 'Alta St offices' },
                { coords = vector3(238.44, 224.11, 106.28), label = 'Mirror Park Blvd retail' }
            }
        }
    },

    dispatch = {
        -- Nobody on duty means no generated calls; the city does not burn for
        -- an empty roster.
        minimumOnDuty = 1,
        maxActive = 3,
        interval = { min = 180000, max = 420000 },
        -- An unanswered call gets worse before it gives up.
        escalateAfter = 240000,
        expireAfter = 1200000,
        -- How close a responder must be for the call to count as worked, and
        -- for water/rescue actions to be accepted at all.
        onSceneDistance = 90.0,
        actionDistance = 12.0,
        -- Response bonus window, measured from dispatch to first arrival.
        responseWindow = 180000,
        broadcastToAll = false
    },

    fire = {
        tickInterval = 2000,
        -- Intensity a burning node gains per tick when nobody is on it.
        growth = 2.5,
        -- Growth only applies while the node is below this ceiling.
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
        -- Applied per water report; the client sends one report per tick.
        reportInterval = 400,
        maxLitresPerReport = 90,
        agents = {
            hose = { multiplier = 1.0, range = 14.0, flow = 65 },
            extinguisher = { multiplier = 0.55, range = 6.0, flow = 18 },
            monitor = { multiplier = 1.6, range = 22.0, flow = 120 }
        },
        heat = {
            radius = 5.0,
            damage = 6,
            interval = 1500,
            -- Turnout gear and a charged SCBA cut incoming heat damage.
            gearMultiplier = 0.3
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
        -- Hydrant supply is effectively unlimited, but the truck still has to
        -- be parked next to one for the pump to draw.
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
        -- Backpack extinguisher capacity for a firefighter working away from
        -- an apparatus.
        extinguisherCapacity = 220
    },

    victims = {
        -- Milliseconds of work to free a trapped victim and to treat one.
        extricationTime = 12000,
        treatmentTime = 8000,
        -- Condition lost per simulation tick while a patient waits, scaled by
        -- how bad the scene still is. A patient who reaches zero is lost: the
        -- turnout still pays, the rescue bonus does not.
        deterioration = { trapped = 3.0, freed = 1.5 },
        hospital = vector3(298.68, -584.44, 43.26),
        model = 'a_m_y_business_01'
    },

    hazards = {
        containmentTime = 15000
    },

    ranks = {
        { id = 'probationary', label = 'Probationary', xp = 0, pay = 0.85, certifications = {} },
        { id = 'firefighter', label = 'Firefighter', xp = 750, pay = 1.0, certifications = { 'engine' } },
        { id = 'engineer', label = 'Engineer', xp = 2500, pay = 1.15, certifications = { 'ladder', 'ems' } },
        { id = 'lieutenant', label = 'Lieutenant', xp = 6000, pay = 1.3, certifications = { 'rescue' } },
        { id = 'captain', label = 'Captain', xp = 12000, pay = 1.5, certifications = { 'hazmat' } },
        { id = 'chief', label = 'Battalion Chief', xp = 25000, pay = 1.75, certifications = { 'command' } }
    },

    -- Training an officer can sign off before the rank would grant it.
    certifications = {
        { id = 'engine', label = 'Pump operator', description = 'Drive and operate an engine.' },
        { id = 'ladder', label = 'Aerial operations', description = 'Operate the aerial ladder.' },
        { id = 'ems', label = 'Emergency medical', description = 'Treat and transport patients.' },
        { id = 'rescue', label = 'Technical rescue', description = 'Extrication and confined space.' },
        { id = 'hazmat', label = 'Hazardous materials', description = 'Contain chemical releases.' },
        { id = 'command', label = 'Incident command', description = 'Run the dispatch board.' }
    },

    pay = {
        account = 'bank',
        -- Every responder is paid; the call payout is split between them so a
        -- full crew is not a pay cut but a solo run is not free money either.
        split = true,
        minimumShare = 0.35,
        perFire = 35,
        perVictim = 300,
        perHazard = 250,
        responseBonus = 200,
        -- Multiplied into the payout when the call is resolved with every
        -- victim alive.
        cleanSceneBonus = 1.15
    },

    hud = {
        enabled = true,
        x = 0.015,
        y = 0.72
    }
}
