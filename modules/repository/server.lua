DAG.Repository = DAG.Repository or {}
local Repository = DAG.Repository

-- Creates resource-owned persistence without pretending to own framework data.
-- Use Bridge methods for framework players, money, jobs, and inventory.
function Repository.Create(collection, options)
    options = options or {}
    assert(type(collection) == 'string' and collection ~= '', 'Invalid repository collection')

    -- Validation failures return `nil, message` instead of throwing: these are
    -- usually driven by client input, and a rejected record should not unwind
    -- the event handler that produced it.
    local function validate(value, operation)
        if not options.validate then return true end
        local valid, message = options.validate(value, operation)
        if valid then return true end
        return false, message or ('Invalid %s record'):format(collection)
    end

    local repository = {}

    function repository.get(id) return DAG.Storage.Get(collection, id) end
    function repository.all() return DAG.Storage.All(collection) end
    function repository.find(predicate) return DAG.Storage.Find(collection, predicate) end
    function repository.delete(id) return DAG.Storage.Delete(collection, id) end

    function repository.count()
        local total = 0
        for _ in pairs(DAG.Storage.All(collection)) do total = total + 1 end
        return total
    end

    function repository.save(id, value)
        if type(value) ~= 'table' then return nil, 'A record must be a table' end
        local valid, message = validate(value, 'save')
        if not valid then return nil, message end
        return DAG.Storage.Set(collection, id, value)
    end

    function repository.update(id, changes)
        if type(changes) ~= 'table' then return nil, 'Changes must be a table' end
        local record = DAG.Storage.Get(collection, id) or {}
        for key, value in pairs(changes) do record[key] = value end

        local valid, message = validate(record, 'update')
        if not valid then return nil, message end
        return DAG.Storage.Set(collection, id, record)
    end

    function repository.can(source, id, action)
        local record = DAG.Storage.Get(collection, id)
        if not record then return false end
        if options.authorize then return options.authorize(source, record, action) == true end
        return DAG.Access.Allowed(source, record.access, action)
    end

    return repository
end

exports('GetRepository', function() return Repository end)
