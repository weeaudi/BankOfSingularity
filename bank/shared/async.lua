local computer = require('computer')
local M = {}

local runq = {}
local waiters = {}
local sleepers = {}

local function enqueue(co, ...) runq[#runq + 1] = {co = co, args = {...}} end

function M.async(fn)
    local co = coroutine.create(fn)
    enqueue(co)
    return co
end

function M.awaitEvent(eventName, pred)
    return coroutine.yield({t = "event", name = eventName, pred = pred})
end

function M.sleep(sec)
    return coroutine.yield({t = "sleep", untilT = computer.uptime() + sec})
end

local function resumeTask(co, ...)
    local ok, req = coroutine.resume(co, ...)
    if not ok then return end
    if coroutine.status(co) == 'dead' then return end

    if type(req) == 'table' and req.t == 'event' then
        waiters[req.name] = waiters[req.name] or {}
        table.insert(waiters[req.name], {co = co, pred = req.pred})
    elseif type(req) == 'table' and req.t == 'sleep' then
        table.insert(sleepers, {co = co, untilT = req.untilT})
    else
        enqueue(co)
    end
end

local function pumpSleep()
    local now = computer.uptime()
    local keep = {}
    for _, w in ipairs(sleepers) do
        if now >= w.untilT then
            resumeTask(w.co)
        else
            keep[#keep + 1] = w
        end
    end
    sleepers = keep
end

local function dispatch(name, ...)
    local ws = waiters[name]
    if not ws then return end
    waiters[name] = nil
    for _, w in ipairs(ws) do
        if not w.pred or w.pred(name, ...) then
            enqueue(w.co, name)
        else
            waiters[name] = waiters[name] or {}
            table.insert(waiters[name], w)
        end
    end
end

function M.run()
    while true do
        pumpSleep()

        if #runq > 0 then
            local item = table.remove(runq, 1)
            resumeTask(item.co, table.unpack(item.args))
        else
            local name, a, b, c, d, e, f = computer.pullSignal()
            dispatch(name, a, b, c, d, e, f)
        end
    end
end

return M
