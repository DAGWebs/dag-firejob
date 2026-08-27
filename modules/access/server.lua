DAG.Access = DAG.Access or {}
local Access = DAG.Access

-- Generic authorization helper for records owned by the resource using this
-- template. It never changes framework jobs, groups, or permissions.
function Access.Allowed(source, policy, action)
    policy = policy or {}
    if source == 0 or policy.public == true then return true end
    if policy.ace and IsPlayerAceAllowed(source, policy.ace) then return true end

    local identifier = DAG.Framework.GetIdentifier(source)
    if policy.owner and identifier and policy.owner == identifier then return true end

    local member = identifier and policy.members and policy.members[identifier]
    if member == true then return true end
    if type(member) == 'table' and (member[action] == true or member['*'] == true) then return true end

    -- GetJob returns nil on frameworks that cannot report jobs. An unknown job
    -- is a denial, never a match against a policy entry.
    if policy.jobs then
        local job = DAG.Framework.GetJob(source)
        local minimumGrade = job and policy.jobs[job.name]
        if minimumGrade ~= nil and job.grade >= (tonumber(minimumGrade) or 0) then return true end
    end

    return false
end

function Access.Require(source, policy, action)
    if Access.Allowed(source, policy, action) then return true end
    DAG.Framework.Notify(source, 'You do not have access to this.', 'error')
    return false
end

exports('GetAccess', function() return Access end)
