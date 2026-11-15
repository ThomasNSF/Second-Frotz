---------------------------------------------------------------------
-- The Text Service's side of the link-message protocol
-- (docs/TEXT_SERVICE.md): receives the core's messages, hands them to a
-- TextService and sends the answers back with the same message key.
--
-- Messages are handled strictly one at a time, in the order they arrive.
-- Handling may yield (a ROM page fault, or waiting for the player to type),
-- and a second message must not start meanwhile, or output would be
-- reordered. Messages that arrive during a wait are queued.
--
-- When no output batch has arrived for `idleSeconds`, the text collected
-- so far is pushed to the host, so a long-running turn does not hold it
-- back.
---------------------------------------------------------------------

local CoroMgr = table.unpack(require("coromgr.luau"))
local TextAPI = require("TextAPI.luau")

export type Options = { idleSeconds: number? }

export type TextServiceLink = {
    service: any,
    post: (number, string, string) -> (),
    idleSeconds: number?,
    idleTimer: any?,
    queue: { { [string]: any } },
    busy: boolean,
    handleMessage: (TextServiceLink, number, string, any) -> (),
    drainSoon: (TextServiceLink) -> (),
    hello: (TextServiceLink) -> (),
    start: (TextServiceLink) -> (),
}

local TextServiceLink = {}
TextServiceLink.__index = TextServiceLink

function TextServiceLink.new(service: any, post: (number, string, string) -> (), options: Options?): TextServiceLink
    local o: Options = options or {}
    return setmetatable({
        service = service,
        post = post,
        idleSeconds = o.idleSeconds,
        idleTimer = nil,
        queue = {},
        busy = false,
    }, TextServiceLink) :: any
end

local function reply(self: TextServiceLink, id: string, payload: { [string]: any }): ()
    self.post(TextAPI.TEXT_REPLY_CHANNEL, lljson.encode(payload), id)
end

local function faultFrom(err: any): { [string]: any }
    return { fatal = true, code = 0, fault = true, message = tostring(err) }
end

-- Restarts the idle countdown after an output batch.
local function armIdle(self: TextServiceLink): ()
    if self.idleSeconds == nil then
        return
    end
    if self.idleTimer ~= nil then
        LLTimers:off(self.idleTimer)
    end
    self.idleTimer = LLTimers:once(self.idleSeconds, function()
        self.idleTimer = nil
        table.insert(self.queue, { idle = true })
        self:drainSoon()
    end)
end

local function process(self: TextServiceLink, item: { [string]: any }): ()
    local service = self.service
    if item.idle then
        service:request("flush")
        return
    end

    local id: string = item.id
    local ok, payload = pcall(lljson.decode, item.message)
    if not ok or typeof(payload) ~= "table" then
        reply(self, id, { type = TextAPI.TS_RES, fault = "the message could not be read", wroteRam = false })
        return
    end

    local kind = payload.type
    if kind == TextAPI.TS_CONFIG then
        local result = service:config(payload)
        if payload.resumed == true and result.ok == true then
            service.host:write("\n[The display was reset.]\n")
        end
        result.type = TextAPI.TS_CONFIG_RES
        reply(self, id, result)
    elseif kind == TextAPI.TS_OUT then
        local err, wrote = service:out(payload.e or {})
        reply(self, id, { type = TextAPI.TS_ACK, seq = payload.seq, err = err, wroteRam = wrote })
        armIdle(self)
    elseif kind == TextAPI.TS_REQ then
        local result = service:request(payload.op, payload.args, payload.pre)
        result.type = TextAPI.TS_RES
        reply(self, id, result)
    elseif kind == TextAPI.TS_RESET then
        local resetOk, err = pcall(service.reset, service)
        reply(self, id, { type = TextAPI.TS_ACK, err = if resetOk then nil else faultFrom(err), wroteRam = true })
    elseif kind == TextAPI.TS_END then
        local endOk, err = pcall(service.finish, service, payload.reason, payload.error)
        reply(self, id, { type = TextAPI.TS_ACK, err = if endOk then nil else faultFrom(err), wroteRam = false })
    else
        reply(self, id, { type = TextAPI.TS_RES, fault = `unknown message type: {tostring(kind)}`, wroteRam = false })
    end
end

-- Handles queued messages one after another. A bug in a handler is
-- reported to the core as a fault reply instead of stopping the service.
local function drain(self: TextServiceLink): ()
    while #self.queue > 0 do
        local item = table.remove(self.queue, 1) :: { [string]: any }
        local ok, err = pcall(process, self, item)
        if not ok and item.id ~= nil then
            reply(self, item.id, { type = TextAPI.TS_RES, fault = tostring(err), wroteRam = true })
        end
    end
    self.busy = false
end

function TextServiceLink.drainSoon(self: TextServiceLink): ()
    if self.busy then
        return
    end
    self.busy = true
    CoroMgr:create_task(function()
        drain(self)
    end)
end

-- The link_message handler: the core's channel only.
function TextServiceLink:handleMessage(channel: number, message: string, id: any): ()
    if channel ~= TextAPI.TEXT_CHANNEL then
        return
    end
    table.insert(self.queue, { message = message, id = tostring(id) })
    self:drainSoon()
end

-- Tells the core that this script has started (or restarted).
function TextServiceLink:hello(): ()
    self.post(TextAPI.TEXT_REPLY_CHANNEL,
        lljson.encode({ type = TextAPI.TS_HELLO, version = TextAPI.PROTOCOL_VERSION }), "")
end

function TextServiceLink:start(): ()
    LLEvents:on("link_message", function(_sender: number, channel: number, message: string, id: any)
        self:handleMessage(channel, message, id)
    end)
end

return TextServiceLink
