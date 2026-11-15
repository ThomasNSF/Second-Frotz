---------------------------------------------------------------------
-- Shared setup for the opcode tests that check what the core sends to the
-- Text Service (TextOpcodeTests, IoOpcodeTests). Nothing here involves
-- the Text Service itself, so these scripts do not carry its code: the
-- transport only records, and answers requests from a table.
---------------------------------------------------------------------

local ZState = require("../VM/ZState.luau")
local ZOpcodes = require("../VM/ZOpcodes.luau")
local ZTextClient = require("../VM/ZTextClient.luau")
local TestFramework = require("TestFramework.luau")

local TextTestSupport = {}

-- A transport that records what the client sends, in order. `all` is
-- every output entry (from batches and from requests' `pre`) flattened in
-- the order the service would see them; `requests` is each request.
-- `replies[op]` is the reply to give (a table, or a function of the
-- request's args returning one); `acks` are batch acknowledgements.
function TextTestSupport.newTransport(): any
    local t: any = { all = {}, batches = {}, requests = {}, replies = {}, log = {}, sent = 0 }
    function t:send(entries: { { any } })
        self.sent += 1
        table.insert(self.batches, entries)
        for _, entry in entries do
            table.insert(self.all, entry)
        end
        table.insert(self.log, "out")
        return self.sent
    end
    function t:wait(_handle: number)
        return nil, false
    end
    function t:request(op: string, args: any, pre: any)
        for _, entry in pre or {} do
            table.insert(self.all, entry)
        end
        table.insert(self.requests, { op = op, args = args, pre = pre })
        table.insert(self.log, "req:" .. op)
        local reply = self.replies[op]
        if typeof(reply) == "function" then
            reply = reply(args)
        end
        return reply or {}
    end
    function t:config()
        return { ok = true }
    end
    function t:reset()
        table.insert(self.log, "reset")
    end
    function t:finish(reason: string)
        table.insert(self.log, "finish:" .. reason)
    end
    return t
end

-- A fresh state over the loaded story, wired to a recording transport.
-- `routineResults` are what state.directCall returns in turn; the
-- routines it is asked to call are recorded in the returned list.
-- The state is built once and reset for each call: a ZState owns a 4 KB
-- stack buffer, and these scripts are too tight on memory to leave one
-- behind as garbage after every test.
local sharedState: ZState.ZState? = nil

local function stateFor(memory: any): ZState.ZState
    local state = sharedState
    if state == nil or state.memory ~= memory then
        state = TestFramework.freshState(memory)
        sharedState = state
        return state
    end
    local top = buffer.len(state.stack) / 2
    state.header = memory:readHeader()
    state.pc = 0
    state.sp = top
    state.fp = top
    state.frameCount = 0
    state.zargc = 0
    state.finished = 0
    state.warningCounts = {}
    return state
end

function TextTestSupport.newVm(memory: any, routineResults: { number }?): (ZState.ZState, any, any, { number })
    local state = stateFor(memory)
    local transport = TextTestSupport.newTransport()
    local client = ZTextClient.new(transport, memory)
    ZOpcodes.attachText(state, client)
    local asked: { number } = {}
    local results = routineResults or {}
    state.directCall = function(addr: number): number
        table.insert(asked, addr)
        return results[#asked] or 0
    end
    return state, transport, client, asked
end

-- Everything the story has printed or configured so far, as entries: the
-- pending batch is sent first.
function TextTestSupport.entries(client: any, transport: any): { { any } }
    client:flush()
    return transport.all
end

-- Z-string words for a list of Z-characters (three to a word, padded
-- with 5s, end bit on the last), written independently of any module.
function TextTestSupport.words(zchars: { number }): { number }
    local result = {}
    for i = 1, #zchars, 3 do
        local word = (zchars[i] * 32 + (zchars[i + 1] or 5)) * 32 + (zchars[i + 2] or 5)
        if i + 3 > #zchars then
            word += 0x8000
        end
        table.insert(result, word)
    end
    return result
end

return TextTestSupport
