---------------------------------------------------------------------
-- Tests for the two ends of the Text Service link: ZTextLink (the core's
-- transport) and TextServiceLink (the service's message loop). Both are
-- driven here with an injected `post` function and hand-made messages, so
-- the test needs no second script, no story and no ROM cards.
---------------------------------------------------------------------

local ZTextLink = require("../VM/ZTextLink.luau")
local TextServiceLink = require("../VM/TextServiceLink.luau")
local TextAPI = require("../VM/TextAPI.luau")
local CoroMgr, await_event = table.unpack(require("../VM/coromgr.luau"))
local TestFramework = require("TestFramework.luau")

local runTest = TestFramework.run
local assertEqual = TestFramework.assertEqual
local assertTrue = TestFramework.assertTrue

-- Collects what a link posts: {channel, msg (decoded), id}.
local function recorder()
    local sent = {}
    local function post(channel: number, text: string, id: string)
        table.insert(sent, { channel = channel, msg = lljson.decode(text), id = id })
    end
    return sent, post
end

local function deliver(link: any, channel: number, payload: any, id: string)
    link:handleMessage(channel, lljson.encode(payload), id)
end

local function runAllTests()
    ------------------------------------------------------------------
    -- ZTextLink (core side)
    ------------------------------------------------------------------

    runTest("send posts a numbered TS_OUT; an acknowledgement that came early is kept", function()
        local sent, post = recorder()
        local link = ZTextLink.new({ post = post })
        local handle = link:send({ { "nl" } })
        assertEqual(#sent, 1)
        assertEqual(sent[1].channel, TextAPI.TEXT_CHANNEL)
        assertEqual(sent[1].msg.type, TextAPI.TS_OUT)
        assertEqual(sent[1].msg.seq, 1)
        assertEqual(sent[1].msg.e[1][1], "nl")
        deliver(link, TextAPI.TEXT_REPLY_CHANNEL, { type = TextAPI.TS_ACK, seq = 1, wroteRam = true }, sent[1].id)
        local err, wrote = link:wait(handle)
        assertEqual(err, nil)
        assertEqual(wrote, true)
        assertEqual(link:send({ { "nl" } }) ~= nil, true)
        assertEqual(sent[2].msg.seq, 2, "sequence numbers count up")
    end)

    runTest("wait returns when the acknowledgement arrives, with its error", function()
        local sent, post = recorder()
        local link = ZTextLink.new({ post = post })
        local handle = link:send({ { "nl" } })
        local gotErr, gotWrote
        local finished = false
        CoroMgr:create_task(function()
            gotErr, gotWrote = link:wait(handle)
            finished = true
        end)
        assertEqual(finished, false, "still waiting")
        deliver(link, TextAPI.TEXT_REPLY_CHANNEL,
            { type = TextAPI.TS_ACK, seq = 1, err = { code = 18, message = "bad" }, wroteRam = false }, sent[1].id)
        assertEqual(finished, true)
        assertEqual(gotErr.code, 18)
        assertEqual(gotWrote, false)
    end)

    runTest("request posts op, args and pre, and returns the reply", function()
        local sent, post = recorder()
        local link = ZTextLink.new({ post = post })
        local result
        CoroMgr:create_task(function()
            result = link:request("read", { text = 100 }, { { "t", "hi" } })
        end)
        assertEqual(sent[1].msg.type, TextAPI.TS_REQ)
        assertEqual(sent[1].msg.op, "read")
        assertEqual(sent[1].msg.args.text, 100)
        assertEqual(sent[1].msg.pre[1][2], "hi")
        assertEqual(result, nil, "no reply yet")
        deliver(link, TextAPI.TEXT_REPLY_CHANNEL,
            { type = TextAPI.TS_RES, status = "line", key = 13, wroteRam = true }, sent[1].id)
        assertEqual(result.status, "line")
        assertEqual(result.key, 13)
        assertEqual(result.wroteRam, true)
    end)

    runTest("replies are matched by key, in any order", function()
        local sent, post = recorder()
        local link = ZTextLink.new({ post = post })
        local first, second
        CoroMgr:create_task(function()
            first = link:request("get_cursor")
        end)
        CoroMgr:create_task(function()
            second = link:request("set_font", { font = 4 })
        end)
        deliver(link, TextAPI.TEXT_REPLY_CHANNEL, { type = TextAPI.TS_RES, value = 2 }, sent[2].id)
        assertEqual(first, nil)
        assertEqual(second.value, 2)
        deliver(link, TextAPI.TEXT_REPLY_CHANNEL, { type = TextAPI.TS_RES, row = 3 }, sent[1].id)
        assertEqual(first.row, 3)
    end)

    runTest("a request nobody answers becomes a fault after the timeout; a late reply is ignored", function()
        local sent, post = recorder()
        local link = ZTextLink.new({ post = post, timeout = 0.2 })
        local reply = link:request("flush")
        assertTrue(reply.fault ~= nil, "fault")
        assertEqual(reply.wroteRam, true, "assume RAM changed")
        deliver(link, TextAPI.TEXT_REPLY_CHANNEL, { type = TextAPI.TS_RES }, sent[1].id)

        local handle = link:send({ { "nl" } })
        local err, wrote = link:wait(handle)
        assertEqual(err.fault, true)
        assertEqual(wrote, true)
    end)

    runTest("reads have no timeout; other requests do", function()
        local link = ZTextLink.new({ post = function() end, timeout = 7 })
        assertEqual(link:timeoutFor("read"), nil)
        assertEqual(link:timeoutFor("read_char"), nil)
        assertEqual(link:timeoutFor("flush"), 7)
        assertEqual(link:timeoutFor("tokenise"), 7)
    end)

    runTest("messages on other channels, for unknown keys, or unreadable are ignored", function()
        local sent, post = recorder()
        local link = ZTextLink.new({ post = post })
        local result
        CoroMgr:create_task(function()
            result = link:request("flush")
        end)
        deliver(link, TextAPI.TEXT_CHANNEL, { type = TextAPI.TS_RES }, sent[1].id)
        deliver(link, TextAPI.TEXT_REPLY_CHANNEL, { type = TextAPI.TS_RES }, "no-such-key")
        link:handleMessage(TextAPI.TEXT_REPLY_CHANNEL, "not json {", "no-such-key")
        assertEqual(result, nil, "still waiting")
        link:handleMessage(TextAPI.TEXT_REPLY_CHANNEL, "not json {", sent[1].id)
        assertTrue(result ~= nil and result.fault ~= nil, "an unreadable reply to a waiting request is a fault")
    end)

    runTest("config remembers the configuration and sends the protocol version", function()
        local sent, post = recorder()
        local link = ZTextLink.new({ post = post })
        local result
        CoroMgr:create_task(function()
            result = link:config({ pageSize = 256, storySize = 1000, staticBase = 600, ramPrefix = "zr" })
        end)
        assertEqual(sent[1].msg.type, TextAPI.TS_CONFIG)
        assertEqual(sent[1].msg.version, TextAPI.PROTOCOL_VERSION)
        assertEqual(sent[1].msg.pageSize, 256)
        assertEqual(sent[1].msg.ramPrefix, "zr")
        deliver(link, TextAPI.TEXT_REPLY_CHANNEL,
            { type = TextAPI.TS_CONFIG_RES, ok = true, screenRows = 24, screenCols = 80 }, sent[1].id)
        assertEqual(result.ok, true)
        assertEqual(result.screenCols, 80)
        assertEqual(link.lastConfig.staticBase, 600)
    end)

    runTest("configFor reads the fields the service needs from the memory", function()
        local cfg = ZTextLink.configFor({ pageSize = 256, storySize = 9, staticMemoryBase = 4, ramKeyPrefix = "zr_x" })
        assertEqual(cfg.pageSize, 256)
        assertEqual(cfg.storySize, 9)
        assertEqual(cfg.staticBase, 4)
        assertEqual(cfg.ramPrefix, "zr_x")
    end)

    runTest("reset and finish are acknowledged; finish sends only plain error fields", function()
        local sent, post = recorder()
        local link = ZTextLink.new({ post = post })
        local done = 0
        CoroMgr:create_task(function()
            link:reset()
            done += 1
        end)
        assertEqual(sent[1].msg.type, TextAPI.TS_RESET)
        deliver(link, TextAPI.TEXT_REPLY_CHANNEL, { type = TextAPI.TS_ACK }, sent[1].id)
        assertEqual(done, 1)

        CoroMgr:create_task(function()
            link:finish("fatal", { code = 9, message = "boom", trace = function() end, nested = { 1 } })
            done += 1
        end)
        assertEqual(sent[2].msg.type, TextAPI.TS_END)
        assertEqual(sent[2].msg.reason, "fatal")
        assertEqual(sent[2].msg.error.code, 9)
        assertEqual(sent[2].msg.error.message, "boom")
        assertEqual(sent[2].msg.error.trace, nil)
        assertEqual(sent[2].msg.error.nested, nil)
        deliver(link, TextAPI.TEXT_REPLY_CHANNEL, { type = TextAPI.TS_ACK }, sent[2].id)
        assertEqual(done, 2)
    end)

    runTest("TS_HELLO before any story is ignored", function()
        local sent, post = recorder()
        local link = ZTextLink.new({ post = post })
        local hellos = 0
        link.onHello = function()
            hellos += 1
        end
        deliver(link, TextAPI.TEXT_REPLY_CHANNEL, { type = TextAPI.TS_HELLO, version = 1 }, "")
        assertEqual(#sent, 0)
        assertEqual(hellos, 0)
    end)

    runTest("TS_HELLO during a game fails waits and sends the configuration and a reset", function()
        local sent, post = recorder()
        local link = ZTextLink.new({ post = post })
        link.lastConfig = { pageSize = 256, storySize = 1000, staticBase = 600, ramPrefix = "zr" }
        local result
        CoroMgr:create_task(function()
            result = link:request("read", { text = 100 })
        end)
        local hellos = 0
        link.onHello = function()
            hellos += 1
        end
        deliver(link, TextAPI.TEXT_REPLY_CHANNEL, { type = TextAPI.TS_HELLO, version = 1 }, "")
        assertTrue(result ~= nil and result.fault ~= nil, "the waiting read fails")
        assertEqual(#sent, 3)
        assertEqual(sent[2].msg.type, TextAPI.TS_CONFIG)
        assertEqual(sent[2].msg.resumed, true)
        assertEqual(sent[2].msg.pageSize, 256)
        assertEqual(sent[3].msg.type, TextAPI.TS_RESET)
        assertEqual(hellos, 1)
    end)

    ------------------------------------------------------------------
    -- TextServiceLink (service side)
    ------------------------------------------------------------------

    -- A service that records its calls. `gate` makes `out` wait for an
    -- event, to check that messages are handled one at a time.
    local function fakeService()
        local service: any = { calls = {}, written = {}, gate = false }
        service.host = {
            write = function(_, text: string)
                table.insert(service.written, text)
            end,
        }
        function service:config(cfg: any)
            table.insert(self.calls, { "config", cfg })
            return { ok = true, screenRows = 24, screenCols = 80 }
        end
        function service:out(entries: any)
            table.insert(self.calls, { "out", entries })
            if self.gate then
                await_event("tl_gate")
            end
            table.insert(self.calls, { "out done", entries })
            return nil, true
        end
        function service:request(op: string, args: any, pre: any)
            table.insert(self.calls, { "request", op, args, pre })
            if op == "boom" then
                error("service bug")
            end
            return { value = 7, wroteRam = false }
        end
        function service:reset()
            table.insert(self.calls, { "reset" })
            if self.resetFails then
                error("reset broke")
            end
        end
        function service:finish(reason: string, err: any)
            table.insert(self.calls, { "finish", reason, err })
        end
        return service
    end

    local function newServiceLink()
        local sent, post = recorder()
        local service = fakeService()
        local link = TextServiceLink.new(service, post)
        return link, service, sent
    end

    local function ask(link: any, payload: any, id: string)
        link:handleMessage(TextAPI.TEXT_CHANNEL, lljson.encode(payload), id)
    end

    runTest("TS_CONFIG: the service is configured and the answer carries the screen size", function()
        local link, service, sent = newServiceLink()
        ask(link, { type = TextAPI.TS_CONFIG, pageSize = 256, ramPrefix = "zr" }, "k1")
        assertEqual(service.calls[1][1], "config")
        assertEqual(service.calls[1][2].pageSize, 256)
        assertEqual(sent[1].channel, TextAPI.TEXT_REPLY_CHANNEL)
        assertEqual(sent[1].id, "k1")
        assertEqual(sent[1].msg.type, TextAPI.TS_CONFIG_RES)
        assertEqual(sent[1].msg.ok, true)
        assertEqual(sent[1].msg.screenRows, 24)
        assertEqual(#service.written, 0, "no notice for a first configuration")
    end)

    runTest("a resumed configuration tells the player the display was reset", function()
        local link, service = newServiceLink()
        ask(link, { type = TextAPI.TS_CONFIG, pageSize = 256, resumed = true }, "k1")
        assertEqual(#service.written, 1)
        assertTrue(string.find(service.written[1], "display was reset", 1, true) ~= nil, "notice")
    end)

    runTest("TS_OUT: entries go to the service and the acknowledgement carries seq and wroteRam", function()
        local link, service, sent = newServiceLink()
        ask(link, { type = TextAPI.TS_OUT, seq = 5, e = { { "t", "hi" } } }, "k2")
        assertEqual(service.calls[1][2][1][2], "hi")
        assertEqual(sent[1].msg.type, TextAPI.TS_ACK)
        assertEqual(sent[1].msg.seq, 5)
        assertEqual(sent[1].msg.wroteRam, true)
        assertEqual(sent[1].id, "k2")
    end)

    runTest("TS_REQ: op, args and pre reach the service; the reply is TS_RES", function()
        local link, service, sent = newServiceLink()
        ask(link, { type = TextAPI.TS_REQ, op = "set_font", args = { font = 4 }, pre = { { "nl" } } }, "k3")
        assertEqual(service.calls[1][2], "set_font")
        assertEqual(service.calls[1][3].font, 4)
        assertEqual(service.calls[1][4][1][1], "nl")
        assertEqual(sent[1].msg.type, TextAPI.TS_RES)
        assertEqual(sent[1].msg.value, 7)
    end)

    runTest("TS_RESET and TS_END are acknowledged; a failing reset is reported", function()
        local link, service, sent = newServiceLink()
        ask(link, { type = TextAPI.TS_RESET }, "k4")
        assertEqual(service.calls[1][1], "reset")
        assertEqual(sent[1].msg.type, TextAPI.TS_ACK)
        assertEqual(sent[1].msg.err, nil)

        ask(link, { type = TextAPI.TS_END, reason = "fatal", error = { code = 3 } }, "k5")
        assertEqual(service.calls[2][1], "finish")
        assertEqual(service.calls[2][2], "fatal")
        assertEqual(service.calls[2][3].code, 3)
        assertEqual(sent[2].msg.type, TextAPI.TS_ACK)

        service.resetFails = true
        ask(link, { type = TextAPI.TS_RESET }, "k6")
        assertEqual(sent[3].msg.err.fault, true)
        assertTrue(string.find(sent[3].msg.err.message, "reset broke", 1, true) ~= nil, "message")
    end)

    runTest("other channels are ignored; unreadable and unknown messages get a fault reply", function()
        local link, service, sent = newServiceLink()
        link:handleMessage(TextAPI.TEXT_REPLY_CHANNEL, lljson.encode({ type = TextAPI.TS_RESET }), "x")
        link:handleMessage(9000, "{}", "x")
        assertEqual(#sent, 0)
        link:handleMessage(TextAPI.TEXT_CHANNEL, "not json {", "k7")
        assertTrue(sent[1].msg.fault ~= nil, "unreadable")
        ask(link, { type = "TS_NOPE" }, "k8")
        assertTrue(sent[2].msg.fault ~= nil, "unknown")
        assertEqual(#service.calls, 0)
    end)

    runTest("a bug in the service is reported as a fault and later messages still work", function()
        local link, _, sent = newServiceLink()
        ask(link, { type = TextAPI.TS_REQ, op = "boom" }, "k9")
        -- The fake's `request` raises for "boom"; TextService itself never does.
        assertTrue(sent[1].msg.fault ~= nil and string.find(sent[1].msg.fault, "service bug", 1, true) ~= nil, "fault")
        ask(link, { type = TextAPI.TS_REQ, op = "flush" }, "k10")
        assertEqual(sent[2].msg.value, 7)
    end)

    runTest("messages are handled one at a time, in order, even when handling waits", function()
        local link, service, sent = newServiceLink()
        service.gate = true
        ask(link, { type = TextAPI.TS_OUT, seq = 1, e = { { "t", "a" } } }, "m1")
        ask(link, { type = TextAPI.TS_OUT, seq = 2, e = { { "t", "b" } } }, "m2")
        assertEqual(#service.calls, 1, "the second batch waits")
        assertEqual(#sent, 0)
        CoroMgr:handle_event("tl_gate", true, "go")
        assertEqual(#service.calls, 3, "first finished, second started")
        assertEqual(#sent, 1)
        assertEqual(sent[1].msg.seq, 1)
        CoroMgr:handle_event("tl_gate", true, "go")
        assertEqual(#sent, 2)
        assertEqual(sent[2].msg.seq, 2)
        assertEqual(service.calls[1][2][1][2], "a")
        assertEqual(service.calls[3][2][1][2], "b")
    end)

    runTest("an idle notice makes the service flush its text", function()
        local link, service = newServiceLink()
        table.insert(link.queue, { idle = true })
        link:drainSoon()
        assertEqual(service.calls[1][1], "request")
        assertEqual(service.calls[1][2], "flush")
    end)

    runTest("hello announces the script on the reply channel", function()
        local link, _, sent = newServiceLink()
        link:hello()
        assertEqual(sent[1].channel, TextAPI.TEXT_REPLY_CHANNEL)
        assertEqual(sent[1].msg.type, TextAPI.TS_HELLO)
        assertEqual(sent[1].msg.version, TextAPI.PROTOCOL_VERSION)
    end)

    TestFramework.printSummary("Text link tests")
end

print(`Starting Memory: {ll.GetFreeMemory()} bytes`)

CoroMgr:create_task(runAllTests)
