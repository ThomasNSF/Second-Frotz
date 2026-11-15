---------------------------------------------------------------------
-- Tests for ChatHost. No story or ROM cards are needed: chat output is
-- captured by an injected `say`, and the owner's chat is simulated by
-- calling onHeard directly. The chat listener is replaced by recorders
-- that count how many are open.
---------------------------------------------------------------------

local ChatHost = require("../VM/ChatHost.luau")
local ZHost = require("../VM/ZHost.luau")
local CoroutineMgr, _, yield_frame = table.unpack(require("../VM/coromgr.luau"))
local TestFramework = require("TestFramework.luau")

local runTest = TestFramework.run
local assertEqual = TestFramework.assertEqual
local assertTrue = TestFramework.assertTrue

local OWNER = "00000000-0000-0000-0000-000000000001"
local STRANGER = "00000000-0000-0000-0000-000000000002"

local openListeners = 0
local listensOpened = 0

-- A host whose messages are collected in the returned list.
local function newHost(config: ChatHost.ChatHostConfig?): (ChatHost.ChatHost, {string})
    local said: {string} = {}
    local c: ChatHost.ChatHostConfig = config or {}
    c.owner = OWNER
    c.say = function(_channel: number, text: string)
        table.insert(said, text)
    end
    c.listen = function(_channel: number, _handler: any)
        openListeners += 1
        listensOpened += 1
        return listensOpened
    end
    c.unlisten = function(_handle: any, _handler: any)
        openListeners -= 1
    end
    return ChatHost.new(c), said
end

local function heard(host: ChatHost.ChatHost, text: string)
    host:onHeard(0, "Owner", OWNER, text)
end

local function runAllTests()
    runTest("a ChatHost satisfies the ZHost interface", function()
        local host = newHost()
        ZHost.validate(host)
    end)

    runTest("flushOutput joins writes into one message and drops trailing newlines", function()
        local host, said = newHost()
        host:write("Hello")
        host:write(" world\n\n")
        host:flushOutput()
        assertEqual(#said, 1)
        assertEqual(said[1], "Hello world")
    end)

    runTest("blank lines inside the text are kept; empty output says nothing", function()
        local host, said = newHost()
        host:write("one\n\ntwo\n")
        host:flushOutput()
        assertEqual(said[1], "one\n\ntwo")
        host:write("\n")
        host:flushOutput()
        host:flushOutput()
        assertEqual(#said, 1, "no message for output that is only newlines")
    end)

    runTest("long output is split into messages no longer than maxBytes", function()
        local host, said = newHost({ maxBytes = 20 })
        host:write("one two three four five six seven\n")
        host:flushOutput()
        assertEqual(#said, 2)
        assertEqual(said[1], "one two three four")
        assertEqual(said[2], "five six seven")
    end)

    -- Starts a read in a task; the results are filled in when it ends.
    local function startRead(host: ChatHost.ChatHost, timeout: number?)
        local state: { line: string?, timedOut: boolean? } = { line = nil, timedOut = nil }
        CoroutineMgr:create_task(function()
            state.line, state.timedOut = host:readLine(80, timeout)
        end)
        return state
    end

    runTest("onHeard ignores other channels and other speakers, even during a read", function()
        local host = newHost()
        local read = startRead(host)
        host:onHeard(5, "Owner", OWNER, "wrong channel")
        host:onHeard(0, "Stranger", STRANGER, "wrong speaker")
        assertEqual(read.line, nil, "still waiting")
        heard(host, "right")
        assertEqual(read.line, "right")
    end)

    runTest("a line heard when no read is waiting is ignored, not kept", function()
        local host = newHost()
        heard(host, "too early")
        local read = startRead(host)
        assertEqual(read.line, nil, "the early line is gone")
        heard(host, "on time")
        assertEqual(read.line, "on time")
    end)

    runTest("the listener is open only while a read waits", function()
        local host = newHost()
        local before = openListeners
        local opened = listensOpened
        local read = startRead(host)
        assertEqual(openListeners, before + 1, "open during the read")
        assertEqual(listensOpened, opened + 1)
        heard(host, "go")
        assertEqual(read.line, "go")
        assertEqual(openListeners, before, "closed after a line")
        assertEqual(host.listenHandle, nil)

        local timed = startRead(host, 2)
        assertEqual(openListeners, before + 1)
        yield_frame(0.6)
        assertEqual(timed.timedOut, true)
        assertEqual(openListeners, before, "closed after a timeout")
    end)

    runTest("readLine says pending output, waits, and resumes with the owner's next line", function()
        local host, said = newHost()
        host:write("West of House
>")
        local read = startRead(host)
        assertEqual(said[1], "West of House
>", "output was sent before waiting")
        assertEqual(read.line, nil, "still waiting")
        assertTrue(host.waiting, "waiting flag")

        host:onHeard(0, "Stranger", STRANGER, "ignored")
        assertEqual(read.line, nil, "a stranger does not wake the reader")

        heard(host, "open mailbox")
        assertEqual(read.line, "open mailbox")
        assertEqual(read.timedOut, false)
        assertEqual(host.waiting, false)
    end)

    runTest("readChar returns the first character of a line, or a newline for an empty line", function()
        local host = newHost()
        local chars: { string } = {}
        CoroutineMgr:create_task(function()
            for _ = 1, 3 do
                table.insert(chars, (host:readChar()))
            end
        end)
        heard(host, "look")
        heard(host, utf8.char(0xE9) .. "a")
        heard(host, "")
        assertEqual(chars[1], "l")
        assertEqual(chars[2], utf8.char(0xE9), "a multibyte first character stays whole")
        assertEqual(chars[3], "
")
    end)

    runTest("readLine with a timeout returns a line said in time, without timing out", function()
        local host = newHost()
        local read = startRead(host, 50)  -- five seconds
        assertTrue(host.waiting, "waiting")
        heard(host, "quick")
        assertEqual(read.line, "quick")
        assertEqual(read.timedOut, false)
    end)

    runTest("readLine times out: empty line, no longer waiting, and a later line is not heard", function()
        local host = newHost()
        local read = startRead(host, 2)  -- 0.2 seconds
        assertEqual(read.timedOut, nil, "not yet")
        yield_frame(0.6)
        assertEqual(read.line, "")
        assertEqual(read.timedOut, true)
        assertEqual(host.waiting, false)

        heard(host, "late")
        local next = startRead(host)
        assertEqual(next.line, nil, "the late line is not kept for the next read")
        heard(host, "on time")
        assertEqual(next.line, "on time")
    end)

    runTest("readChar times out the same way", function()
        local host = newHost()
        local char: string? = nil
        local timedOut: boolean? = nil
        CoroutineMgr:create_task(function()
            char, timedOut = host:readChar(2)
        end)
        yield_frame(0.6)
        assertEqual(char, "")
        assertEqual(timedOut, true)
    end)

    runTest("fatal describes the error table; quit says the story ended", function()
        local host, said = newHost()
        host:write("last words\n")
        host:fatal({ fatal = true, code = 100, message = "Unsupported opcode: read", pc = 0x20FB })
        assertEqual(said[1], "last words")
        assertEqual(said[2], "[Unsupported opcode: read (code 100, PC 20fb)]")

        host:fatal("boom")
        assertEqual(said[3], "[boom]")

        host:write("bye\n")
        host:quit()
        assertEqual(said[4], "bye")
        assertEqual(said[5], "[The story has ended.]")
    end)

    runTest("the real listener is registered during a read and removed after it", function()
        local host = ChatHost.new({ owner = OWNER, say = function() end })
        local before = #LLEvents:handlers("listen")
        local read = startRead(host, 50)
        assertEqual(#LLEvents:handlers("listen"), before + 1, "handler registered")
        assertTrue(host.listenHandle ~= nil, "listen handle")
        host:onHeard(0, "Owner", OWNER, "done")
        assertEqual(read.line, "done")
        assertEqual(#LLEvents:handlers("listen"), before, "handler removed")
        assertEqual(host.listenHandle, nil)
    end)

    TestFramework.printSummary("ChatHost tests")
end

print(`Starting Memory: {ll.GetFreeMemory()} bytes`)

CoroutineMgr:create_task(runAllTests)
