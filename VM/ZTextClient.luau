---------------------------------------------------------------------
-- The core's side of the Text Service protocol (docs/TEXT_SERVICE.md).
--
-- The print and input opcodes call this instead of printing or reading
-- themselves. Output entries are collected and sent in batches; anything
-- that needs an answer is a synchronous request. The client keeps the
-- shared-RAM rules for the core:
--   R1  flush the memory's dirty pages before a request,
--   R3  drop the memory's cached pages after a reply that wrote RAM,
--   R6  wait for earlier output before a story write to a string table,
--   R7  while a stream 3 redirect is open, every entry is synchronous
--       (the service writes into RAM, so the core may not run meanwhile).
--
-- It talks to the service through a transport (link messages in
-- production, a direct call in tests):
--   transport:send(entries) -> handle        start delivering a batch
--   transport:wait(handle) -> error, wrote   its acknowledgement
--   transport:request(op, args, pre) -> reply
--   transport:config(cfg) -> reply
--   transport:reset()
--   transport:finish(reason, error)
--
-- Requires no other VM module. Runs in the VM coroutine, since waiting
-- yields.
---------------------------------------------------------------------

-- Output entries are sent when they reach this many bytes of JSON (and
-- see MAX_PENDING_MEMORY).
local BATCH_BYTES = 2000

-- Queued entries are Lua tables, which cost far more memory than their
-- JSON, so a batch is also sent when the entries waiting would take this
-- many bytes (estimated; see memoryBytes). The core has little to spare.
local MAX_PENDING_MEMORY = 2500

-- At most this many batches may be unacknowledged (the link-message queue
-- holds 64 events).
local MAX_OUTSTANDING = 2

export type Range = { number }  -- {first, last}, inclusive

export type ZTextClient = {
    transport: any,
    memory: any,
    pending: { { any } },
    pendingBytes: number,
    pendingMemory: number,
    outstanding: { any },
    redirect: number,
    ranges: { Range },
    onError: (any) -> (),
    queue: (ZTextClient, { any }) -> (),
    flush: (ZTextClient) -> (),
    settle: (ZTextClient) -> (),
    request: (ZTextClient, string, { [string]: any }?) -> { [string]: any },
    barrier: (ZTextClient) -> (),
    setWatch: (ZTextClient, { Range }) -> (),
    isWatched: (ZTextClient, number) -> boolean,
    setRedirect: (ZTextClient, number) -> (),
    config: (ZTextClient, any) -> { [string]: any },
    reset: (ZTextClient) -> (),
    finish: (ZTextClient, string, any?) -> (),
}

local ZTextClient = {}
ZTextClient.__index = ZTextClient

ZTextClient.BATCH_BYTES = BATCH_BYTES
ZTextClient.MAX_OUTSTANDING = MAX_OUTSTANDING
ZTextClient.MAX_PENDING_MEMORY = MAX_PENDING_MEMORY

-- `onError` receives an error table ({code, message} for a Z-machine
-- error, or {fault = text} for a bug) and must not return: the opcode
-- layer turns it into the story's fatal error with the PC attached.
function ZTextClient.new(transport: any, memory: any, onError: ((any) -> ())?): ZTextClient
    return setmetatable({
        transport = transport,
        memory = memory,
        pending = {},
        pendingBytes = 0,
        pendingMemory = 0,
        outstanding = {},
        redirect = 0,
        ranges = {},
        onError = onError or function(err: any)
            error(err)
        end,
    }, ZTextClient) :: any
end

-- A transport that calls a TextService in the same script, for tests and
-- development. Batches are processed at once, so acknowledgements are
-- already there when asked for.
function ZTextClient.loopback(service: any): any
    return {
        send = function(_, entries: { { any } })
            local err, wrote = service:out(entries)
            return { err = err, wrote = wrote }
        end,
        wait = function(_, handle: any)
            return handle.err, handle.wrote
        end,
        request = function(_, op: string, args: any, pre: any)
            return service:request(op, args, pre)
        end,
        config = function(_, cfg: any)
            return service:config(cfg)
        end,
        reset = function()
            service:reset()
        end,
        finish = function(_, reason: string, err: any)
            service:finish(reason, err)
        end,
    }
end

-- A rough size of an entry as JSON, enough to decide when to send.
local function entryBytes(entry: { any }): number
    local bytes = 4
    for _, value in entry do
        local kind = typeof(value)
        if kind == "string" then
            bytes += #value + 3
        elseif kind == "table" then
            bytes += 8 * (#value + 1)
        else
            bytes += 8
        end
    end
    return bytes
end

-- A rough size in memory: a table costs about 100 bytes before its
-- contents, and each value in it 16 more (plus a string's length).
local function memoryBytes(entry: { any }): number
    local bytes = 100
    for _, value in entry do
        bytes += 16
        if typeof(value) == "string" then
            bytes += #value
        elseif typeof(value) == "table" then
            bytes += 16 * #value + 56
        end
    end
    return bytes
end

-- Applies an acknowledgement: raises the error it carries, and drops the
-- memory's cached pages if the batch wrote RAM (R3).
local function applyAck(self: ZTextClient, handle: any): ()
    local err, wrote = self.transport:wait(handle)
    if wrote then
        self.memory:invalidateRam()
    end
    if err ~= nil then
        self.onError(err)
    end
end

-- Waits for every outstanding batch.
function ZTextClient:settle(): ()
    while #self.outstanding > 0 do
        applyAck(self, table.remove(self.outstanding, 1))
    end
end

-- Sends the pending entries as one batch without waiting for it, unless
-- two batches are already outstanding, in which case the oldest is waited
-- for first.
function ZTextClient:flush(): ()
    if #self.pending == 0 then
        return
    end
    while #self.outstanding >= MAX_OUTSTANDING do
        applyAck(self, table.remove(self.outstanding, 1))
    end
    local entries = self.pending
    self.pending = {}
    self.pendingBytes = 0
    self.pendingMemory = 0
    table.insert(self.outstanding, self.transport:send(entries))
end

-- Adds one output entry. It is sent when the batch is full, and at once
-- (and waited for) while a stream 3 redirect is open.
function ZTextClient:queue(entry: { any }): ()
    -- A run of printed characters becomes one entry holding a list of
    -- codes: {"c", 72, 101, 108}. A table per character would cost about
    -- 100 bytes each, and a story that pads a status line with 80 spaces
    -- would use up the script's memory.
    local kind = entry[1]
    local last = self.pending[#self.pending]
    if (kind == "c" or kind == "u") and last ~= nil and last[1] == kind then
        table.insert(last, entry[2])
        self.pendingBytes += 7
        self.pendingMemory += 16
    else
        table.insert(self.pending, entry)
        self.pendingBytes += entryBytes(entry)
        self.pendingMemory += memoryBytes(entry)
    end
    if self.redirect > 0 then
        self:request("flush")
    elseif self.pendingBytes >= BATCH_BYTES or self.pendingMemory >= MAX_PENDING_MEMORY then
        self:flush()
    end
end

-- A synchronous operation. The pending entries travel with it and are
-- handled first. Raises (through onError) if the reply carries an error.
function ZTextClient:request(op: string, args: { [string]: any }?): { [string]: any }
    self.memory:flush()  -- R1
    local pre = self.pending
    self.pending = {}
    self.pendingBytes = 0
    self.pendingMemory = 0
    local reply = self.transport:request(op, args, if #pre > 0 then pre else nil)
    if reply.wroteRam then
        self.memory:invalidateRam()  -- R3
    end
    self:settle()
    if reply.fault ~= nil then
        self.onError({ fault = reply.fault })
    elseif reply.error ~= nil then
        self.onError({ code = reply.error, message = reply.message })
    end
    return reply
end

-- Waits until everything sent so far has been handled (R6).
function ZTextClient:barrier(): ()
    self:request("barrier")
end

-- The address ranges of the alphabet, abbreviation and Unicode tables.
function ZTextClient:setWatch(ranges: { Range }): ()
    self.ranges = ranges
end

function ZTextClient:isWatched(address: number): boolean
    for _, range in self.ranges do
        if address >= range[1] and address <= range[2] then
            return true
        end
    end
    return false
end

-- Tracks stream 3 redirects opened (+1) and closed (-1) so that entries
-- are synchronous while one is open (R7).
function ZTextClient:setRedirect(delta: number): ()
    self.redirect = math.max(self.redirect + delta, 0)
end

function ZTextClient:config(cfg: any): { [string]: any }
    return self.transport:config(cfg)
end

-- After a restart: send what the story printed first, then reset the
-- service.
function ZTextClient:reset(): ()
    self:flush()
    self:settle()
    self.redirect = 0
    self.transport:reset()
end

-- The story ended or failed: send what is pending and tell the service.
function ZTextClient:finish(reason: string, err: any?): ()
    self:flush()
    self:settle()
    self.transport:finish(reason, err)
end

return ZTextClient
