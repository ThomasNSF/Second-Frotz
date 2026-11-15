---------------------------------------------------------------------
-- The core's link-message transport to the Text Service script
-- (docs/TEXT_SERVICE.md). It implements the transport interface that
-- ZTextClient expects:
--   send(entries) -> handle, wait(handle) -> error, wrote,
--   request(op, args, pre) -> reply, config(cfg), reset(), finish(...)
--
-- Every message that expects an answer carries a fresh key as the link
-- message `id`; the service answers with the same key on the reply
-- channel. Answers are matched through a table of open handles, so a
-- reply that arrives before anyone waits for it is kept.
--
-- Waiting yields, so the calls run in the VM coroutine. A service that
-- does not answer within `timeout` seconds produces a fault reply (the
-- opcode layer turns it into the story's fatal error). Reads wait for a
-- person and have no timeout.
--
-- `post` is the function that sends a link message; tests replace it.
---------------------------------------------------------------------

local CoroMgr, await_event = table.unpack(require("coromgr.luau"))
local TextAPI = require("TextAPI.luau")

local TIMEOUT_SECONDS = 30

export type Handle = { id: string, what: string, reply: { [string]: any }? }

export type ZTextLink = {
    post: (number, string, string) -> (),
    timeout: number,
    handles: { [string]: Handle },
    sequence: number,
    lastConfig: { [string]: any }?,
    onHello: (() -> ())?,
    log: ((string) -> ())?,
    send: (ZTextLink, { { any } }) -> Handle,
    wait: (ZTextLink, Handle) -> (any, boolean),
    request: (ZTextLink, string, { [string]: any }?, { { any } }?) -> { [string]: any },
    config: (ZTextLink, { [string]: any }) -> { [string]: any },
    reset: (ZTextLink) -> (),
    finish: (ZTextLink, string, any?) -> (),
    handleMessage: (ZTextLink, number, string, any) -> (),
    start: (ZTextLink) -> (),
    timeoutFor: (ZTextLink, string) -> number?,
}

export type Options = { post: ((number, string, string) -> ())?, timeout: number?, log: ((string) -> ())? }

local ZTextLink = {}
ZTextLink.__index = ZTextLink

local function defaultPost(channel: number, text: string, id: string): ()
    ll.MessageLinked(LINK_THIS, channel, text, id)
end

function ZTextLink.new(options: Options?): ZTextLink
    local o: Options = options or {}
    return setmetatable({
        post = o.post or defaultPost,
        timeout = o.timeout or TIMEOUT_SECONDS,
        handles = {},
        sequence = 0,
        lastConfig = nil,
        onHello = nil,
        log = o.log,
    }, ZTextLink) :: any
end

-- The fields of the memory that the service needs to attach to the same
-- story (the TS_CONFIG payload).
function ZTextLink.configFor(memory: any): { [string]: any }
    return {
        pageSize = memory.pageSize,
        storySize = memory.storySize,
        staticBase = memory.staticMemoryBase,
        ramPrefix = memory.ramKeyPrefix,
    }
end

-- Only plain values travel in an error: no functions, no nested tables.
local function plain(err: any): any
    if typeof(err) ~= "table" then
        return err
    end
    local copy = {}
    for key, value in err do
        local kind = typeof(value)
        if kind == "string" or kind == "number" or kind == "boolean" then
            copy[key] = value
        end
    end
    return copy
end

-- Reads wait for a person, so they have no timeout.
function ZTextLink:timeoutFor(op: string): number?
    if op == "read" or op == "read_char" then
        return nil
    end
    return self.timeout
end

local function submit(self: ZTextLink, payload: { [string]: any }, what: string): Handle
    local id = tostring(ll.GenerateKey())
    local handle: Handle = { id = id, what = what, reply = nil }
    self.handles[id] = handle
    local text = lljson.encode(payload)
    if self.log ~= nil then
        self.log(`link >> {payload.type}{if payload.op then " " .. payload.op else ""} {#text} bytes, free {ll.GetFreeMemory()}`)
    end
    self.post(TextAPI.TEXT_CHANNEL, text, id)
    return handle
end

-- Waits for the reply to `handle`; a missing reply becomes a fault.
local function await(self: ZTextLink, handle: Handle, seconds: number?): { [string]: any }
    if handle.reply == nil then
        await_event(`tapi{handle.id}`, seconds)
    end
    self.handles[handle.id] = nil
    local reply = handle.reply
    if reply == nil then
        return { fault = `the Text Service did not answer ({handle.what})`, wroteRam = true }
    end
    return reply
end

function ZTextLink:send(entries: { { any } }): Handle
    self.sequence += 1
    return submit(self, { type = TextAPI.TS_OUT, seq = self.sequence, e = entries }, "output")
end

function ZTextLink:wait(handle: Handle): (any, boolean)
    local reply = await(self, handle, self.timeout)
    if reply.fault ~= nil then
        return { fatal = true, code = 0, fault = true, message = tostring(reply.fault) }, true
    end
    return reply.err, reply.wroteRam == true
end

function ZTextLink:request(op: string, args: { [string]: any }?, pre: { { any } }?): { [string]: any }
    local handle = submit(self, { type = TextAPI.TS_REQ, op = op, args = args, pre = pre }, op)
    return await(self, handle, self:timeoutFor(op))
end

function ZTextLink:config(cfg: { [string]: any }): { [string]: any }
    self.lastConfig = table.clone(cfg)
    local payload = table.clone(cfg)
    payload.type = TextAPI.TS_CONFIG
    payload.version = TextAPI.PROTOCOL_VERSION
    local reply = await(self, submit(self, payload, "config"), self.timeout)
    if reply.fault ~= nil then
        return { ok = false, message = tostring(reply.fault) }
    end
    return reply
end

function ZTextLink:reset(): ()
    local err = self:wait(submit(self, { type = TextAPI.TS_RESET }, "reset"))
    if err ~= nil then
        error("Text Service reset failed: " .. tostring(err.message))
    end
end

function ZTextLink:finish(reason: string, err: any?): ()
    self:wait(submit(self, { type = TextAPI.TS_END, reason = reason, error = plain(err) }, "end"))
end

-- The service restarted and has lost its state. Anything waiting for it
-- will never be answered, so those waits fail; a game in progress gets
-- the configuration again, followed by a reset (the service tells the
-- player that the display was reset).
local function hello(self: ZTextLink): ()
    if self.lastConfig == nil then
        return
    end
    local open = {}
    for _, handle in self.handles do
        table.insert(open, handle)
    end
    self.handles = {}
    for _, handle in open do
        handle.reply = { fault = "the Text Service restarted", wroteRam = true }
        CoroMgr:handle_event(`tapi{handle.id}`, true, "reply")
    end

    local payload = table.clone(self.lastConfig)
    payload.type = TextAPI.TS_CONFIG
    payload.version = TextAPI.PROTOCOL_VERSION
    payload.resumed = true
    self.post(TextAPI.TEXT_CHANNEL, lljson.encode(payload), tostring(ll.GenerateKey()))
    self.post(TextAPI.TEXT_CHANNEL, lljson.encode({ type = TextAPI.TS_RESET }), tostring(ll.GenerateKey()))
    if self.onHello ~= nil then
        self.onHello()
    end
end

-- The link_message handler: replies on the reply channel only.
function ZTextLink:handleMessage(channel: number, message: string, id: any): ()
    if channel ~= TextAPI.TEXT_REPLY_CHANNEL then
        return
    end
    local key = tostring(id)
    local handle = self.handles[key]
    if self.log ~= nil and handle ~= nil then
        self.log(`link << {handle.what} {#message} bytes, free {ll.GetFreeMemory()}`)
    end
    local ok, payload = pcall(lljson.decode, message)
    if not ok or typeof(payload) ~= "table" then
        if handle == nil then
            return
        end
        payload = { fault = "the Text Service sent an unreadable reply", wroteRam = true }
    end
    if handle ~= nil then
        self.handles[key] = nil
        handle.reply = payload
        CoroMgr:handle_event(`tapi{key}`, true, "reply")
    elseif payload.type == TextAPI.TS_HELLO then
        hello(self)
    end
end

-- Starts receiving replies.
function ZTextLink:start(): ()
    LLEvents:on("link_message", function(_sender: number, channel: number, message: string, id: any)
        self:handleMessage(channel, message, id)
    end)
end

return ZTextLink
