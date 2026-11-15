---------------------------------------------------------------------
-- A ZHost that plays the story over public chat: the story's text is
-- said on a chat channel (channel 0 by default) and the owner's chat
-- lines are the game's input.
--
-- Output is collected as the VM writes it and sent, in messages that fit
-- llSay's 1024-byte limit, whenever the game asks for input, fails, or
-- ends. Input is the owner's chat only, and the host listens only while
-- a read is waiting: chat said at any other time is not heard.
--
-- Provides none of the optional screen capabilities, so the screen
-- opcodes take their plain-text defaults.
---------------------------------------------------------------------

local CoroMgr, await_event = table.unpack(require("coromgr.luau"))
local ChatText = require("ChatText.luau")

export type ChatHostConfig = {
    channel: number?,                  -- default 0
    maxBytes: number?,                 -- default ChatText.MAX_BYTES
    owner: any?,                       -- default ll.GetOwner()
    say: ((number, string) -> ())?,    -- default ll.Say; tests inject a recorder
    -- Open and close the chat listener around a read (tests inject
    -- recorders). `listen` returns a handle for `unlisten`.
    listen: ((number, any) -> any)?,
    unlisten: ((any, any) -> ())?,
}

export type ChatHost = {
    channel: number,
    maxBytes: number,
    ownerKey: string,
    say: (number, string) -> (),
    listen: (number, any) -> any,
    unlisten: (any, any) -> (),
    pending: { string },
    waiting: boolean,
    eventName: string,
    listenHandle: any?,
    listener: any,

    -- ZHost
    write: (ChatHost, string) -> (),
    readLine: (ChatHost, number, number?) -> (string, boolean),
    readChar: (ChatHost, number?) -> (string, boolean),
    fatal: (ChatHost, any) -> (),
    quit: (ChatHost) -> (),

    -- Chat
    onHeard: (ChatHost, number, string, any, string) -> (),
    flushOutput: (ChatHost) -> (),
}

local ChatHost = {}
ChatHost.__index = ChatHost

-- Gives every host its own event name, so two hosts never wake each
-- other's reader.
local hostCount = 0

function ChatHost.new(config: ChatHostConfig?): ChatHost
    local c: ChatHostConfig = config or {}
    hostCount += 1
    local host: any = setmetatable({
        channel = c.channel or 0,
        maxBytes = c.maxBytes or ChatText.MAX_BYTES,
        ownerKey = tostring(c.owner or ll.GetOwner()),
        say = c.say or function(channel: number, text: string)
            ll.Say(channel, text)
        end,
        listen = c.listen or function(channel: number, handler: any)
            LLEvents:on("listen", handler)
            return ll.Listen(channel, "", ll.GetOwner(), "")
        end,
        unlisten = c.unlisten or function(handle: any, handler: any)
            LLEvents:off("listen", handler)
            ll.ListenRemove(handle)
        end,
        pending = {},
        waiting = false,
        eventName = `chatline{hostCount}`,
        listenHandle = nil,
    }, ChatHost)
    host.listener = function(channel: number, name: string, id: any, msg: string)
        host:onHeard(channel, name, id, msg)
    end
    return host
end

-- Handles one heard line. Lines on other channels or from anyone but the
-- owner are ignored, as is anything heard when no read is waiting.
function ChatHost:onHeard(channel: number, _name: string, id: any, msg: string): ()
    if channel ~= self.channel or tostring(id) ~= self.ownerKey then
        return
    end
    if self.waiting then
        self.waiting = false
        CoroMgr:handle_event(self.eventName, true, msg)
    end
end

function ChatHost:write(text: string): ()
    table.insert(self.pending, text)
end

-- Says everything written so far, in pieces that fit one chat message.
-- Trailing newlines are dropped, because chat shows them as blank lines
-- and the story's prompt ends the text.
function ChatHost:flushOutput(): ()
    local text = string.gsub(table.concat(self.pending), "\n+$", "")
    self.pending = {}
    for _, piece in ChatText.split(text, self.maxBytes) do
        self.say(self.channel, piece)
    end
end

-- Returns the next line the owner says, and whether the wait timed out.
-- The chat listener is open only for the duration of the wait. `timeout`
-- is in tenths of a second; nil or 0 waits indefinitely. A timeout
-- returns an empty line (nothing is ever half-typed in chat). `maxLength`
-- is not applied here; the input logic truncates, because it knows what
-- the story can hold.
function ChatHost:readLine(_maxLength: number, timeout: number?): (string, boolean)
    self:flushOutput()
    self.waiting = true
    self.listenHandle = self.listen(self.channel, self.listener)
    local seconds = if timeout ~= nil and timeout > 0 then timeout / 10 else nil
    local ok, line = await_event(self.eventName, seconds)
    self.waiting = false
    self.unlisten(self.listenHandle, self.listener)
    self.listenHandle = nil
    if ok and typeof(line) == "string" then
        return line, false
    elseif line == "timeout" then
        return "", true
    end
    error("chat input failed")
end

-- Chat has no key events, so a character comes from a line: its first
-- character, or a newline if the owner sent an empty line.
function ChatHost:readChar(timeout: number?): (string, boolean)
    local line, timedOut = self:readLine(1, timeout)
    if timedOut then
        return "", true
    elseif line == "" then
        return "\n", false
    end
    return string.sub(line, 1, (utf8.offset(line, 2) or #line + 1) - 1), false
end

local function describe(err: any): string
    if typeof(err) ~= "table" then
        return tostring(err)
    end
    local text = tostring(err.message or "error")
    local details = {}
    if err.code ~= nil then
        table.insert(details, `code {err.code}`)
    end
    if typeof(err.pc) == "number" then
        table.insert(details, string.format("PC %x", err.pc))
    end
    if #details > 0 then
        text ..= ` ({table.concat(details, ", ")})`
    end
    return text
end

function ChatHost:fatal(err: any): ()
    self:flushOutput()
    self.say(self.channel, `[{describe(err)}]`)
end

function ChatHost:quit(): ()
    self:flushOutput()
    self.say(self.channel, "[The story has ended.]")
end

return ChatHost
