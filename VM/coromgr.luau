---------------------------------------------------------------------
--[[
]]

-- Default delay for yield_frame. The effective floor is the sim frame time,
-- so lowering this past that has no effect.
local FRAME_DELAY = 0.1

local CoroutineMgr = {
    -- CoroutineMgrutine -> eventName it’s waiting for
    _coros = {},
    running = false,
}

function CoroutineMgr:create_task(func)
    local coro = coroutine.create(func)
    self._coros[coro] = false
    self:_run_coro(coro)
    return coro
end

function CoroutineMgr:kill_task(coro)
    self._coros[coro] = nil
    if coroutine.status(coro) ~= "dead" then
        coroutine.close(coro)
    end
end

function CoroutineMgr:_run_coro(coro, ...)
    if coroutine.status(coro) == "dead" then
        return
    end

    local old_running = self.running
    self.running = true
    if self._coros[coro] and self._coros[coro].timeout then
        LLTimers:off(self._coros[coro].timeout)
    end

    self._coros[coro] = false
    local ok, event_awaited, timeout = coroutine.resume(coro, ...)
    self.running = old_running

    if not ok then
        print("Error in coroutine " .. ll.GetScriptName() .. ": " .. tostring(event_awaited))
        self._coros[coro] = nil
        return
    end

    -- A task that has finished must not stay in the table: a dead coroutine
    -- is kept alive (stack and all, about 1 KB) as long as it is a key.
    if coroutine.status(coro) == "dead" then
        self._coros[coro] = nil
        return
    end

    local timout_handle = nil
    if typeof(timeout) == "number" and timeout > 0 then
        timout_handle = LLTimers:once(timeout, function()
            self:handle_event(event_awaited, false, "timeout")
        end)
    end
    -- If still alive, 'eventAwaited' is the next event it wants
    self._coros[coro] = { event = event_awaited, timeout = timout_handle }
end

-- True if some live task is waiting for `event_name`. Lets a message
-- handler skip work (such as decoding JSON) for replies nobody asked for.
function CoroutineMgr:is_waiting(event_name)
    for coro, state_info in pairs(self._coros) do
        if state_info and state_info.event == event_name and coroutine.status(coro) ~= "dead" then
            return true
        end
    end
    return false
end

function CoroutineMgr:handle_event(event_name, ...)
    local snapshot = table.clone(self._coros)
    for coro, state_info in pairs(snapshot) do
        if coroutine.status(coro) == "dead" then
            self._coros[coro] = nil
        elseif state_info and state_info.event == event_name then
            self:_run_coro(coro, ...)
        end
    end
end

local function await_event(name, timeout)
    timeout = (typeof(timeout) == "number" and timeout) or nil
    assert(CoroutineMgr.running, ll.GetScriptName() .. " await_event called outside a coroutine!")
    return coroutine.yield(name, timeout)
end

-- Suspends the running task long enough to hand the script back to the event
-- loop, so queued events are serviced during a long compute-bound run such as
-- the VM interpreter loop. Resumption comes from the await timeout, so the
-- event name must be unique per call: a shared name would let one task's
-- timeout resume every other task waiting on it.
local yield_sequence = 0

local function yield_frame(delay)
    yield_sequence += 1
    await_event(`yield{yield_sequence}`, delay or FRAME_DELAY)
end

return {CoroutineMgr, await_event, yield_frame}
