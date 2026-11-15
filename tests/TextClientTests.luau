---------------------------------------------------------------------
-- Tests for ZTextClient: batching, the outstanding-batch limit, requests
-- and the shared-RAM rules (R1 flush before a request, R3 drop after a
-- reply that wrote RAM, R7 synchronous output during a stream 3
-- redirect), error reporting, and the loopback transport.
--
-- Uses a recording transport and a fake memory, so it needs no story, no
-- ROM cards and no Text Service.
---------------------------------------------------------------------

local ZTextClient = require("../VM/ZTextClient.luau")
local CoroutineMgr = table.unpack(require("../VM/coromgr.luau"))
local TestFramework = require("TestFramework.luau")

local runTest = TestFramework.run
local assertEqual = TestFramework.assertEqual
local assertTrue = TestFramework.assertTrue

-- Records everything the client does, in order, as strings in `log`.
local function newTransport()
    local t: any = { log = {}, batches = {}, requests = {}, replies = {}, acks = {}, sent = 0 }
    function t:send(entries: { { any } })
        self.sent += 1
        local id = self.sent
        table.insert(self.batches, entries)
        table.insert(self.log, `out{id}`)
        return id
    end
    function t:wait(handle: number)
        table.insert(self.log, `wait{handle}`)
        local ack = self.acks[handle]
        if ack then
            return ack[1], ack[2]
        end
        return nil, false
    end
    function t:request(op: string, args: any, pre: any)
        table.insert(self.log, "req:" .. op)
        table.insert(self.requests, { op = op, args = args, pre = pre })
        local reply = self.replies[op]
        if typeof(reply) == "function" then
            reply = reply(args)
        end
        return reply or {}
    end
    function t:config(cfg: any)
        table.insert(self.log, "config")
        return { ok = true }
    end
    function t:reset()
        table.insert(self.log, "reset")
    end
    function t:finish(reason: string, err: any)
        table.insert(self.log, "finish:" .. reason)
    end
    return t
end

-- Stands in for ZMemory: counts flushes and invalidations.
local function newMemory()
    local m: any = { flushes = 0, invalidations = 0 }
    function m:flush()
        self.flushes += 1
    end
    function m:invalidateRam()
        self.invalidations += 1
    end
    return m
end

-- A client with a recording transport, a fake memory, and an error list.
local function newClient()
    local transport = newTransport()
    local memory = newMemory()
    local errors: { any } = {}
    local client = ZTextClient.new(transport, memory, function(err: any)
        table.insert(errors, err)
    end)
    return client, transport, memory, errors
end

local function runAllTests()
    runTest("queue holds entries until flush, then sends them as one batch in order", function()
        local client, transport = newClient()
        client:queue({ "c", 65 })
        client:queue({ "nl" })
        assertEqual(#transport.log, 0, "nothing sent yet")
        client:flush()
        assertEqual(transport.log[1], "out1")
        assertEqual(#transport.batches[1], 2)
        assertEqual(transport.batches[1][1][2], 65)
        assertEqual(transport.batches[1][2][1], "nl")
        client:flush()
        assertEqual(#transport.log, 1, "an empty flush sends nothing")
    end)

    runTest("a batch is sent by itself when it reaches the size limit", function()
        local client, transport = newClient()
        local text = string.rep("x", 400)  -- about 410 bytes of JSON each
        for _ = 1, 4 do
            client:queue({ "t", text })
        end
        assertEqual(#transport.batches, 0, "four entries are under the 2,000-byte limit")
        client:queue({ "t", text })
        assertEqual(#transport.batches, 1, "the fifth reaches it")
        assertEqual(#transport.batches[1], 5)
        assertEqual(client.pendingBytes, 0, "the pending size starts again")
    end)

    runTest("a run of printed characters is combined into one entry", function()
        local client, transport = newClient()
        for _, code in { 72, 105, 33 } do
            client:queue({ "c", code })
        end
        client:queue({ "u", 0x263A })
        client:queue({ "u", 0x263B })
        client:queue({ "c", 10 })
        client:flush()
        local batch = transport.batches[1]
        assertEqual(#batch, 3)
        assertEqual(table.concat(batch[1], ","), "c,72,105,33")
        assertEqual(table.concat(batch[2], ","), `u,{0x263A},{0x263B}`)
        assertEqual(table.concat(batch[3], ","), "c,10", "a different kind starts a new entry")
    end)

    runTest("many separate entries are sent once their memory adds up, long before 2,000 bytes of JSON", function()
        local client, transport = newClient()
        for _ = 1, 40 do
            client:queue({ "nl" })
        end
        assertEqual(#transport.batches, 1, "40 entries of about 116 bytes each reach the memory limit")
        assertTrue(#transport.batches[1] < 40, "sent before the last")
        assertEqual(client.pendingMemory < ZTextClient.MAX_PENDING_MEMORY, true)
    end)

    runTest("80 printed spaces stay one small entry and send nothing", function()
        local client, transport = newClient()
        for _ = 1, 80 do
            client:queue({ "c", 32 })
        end
        assertEqual(#transport.batches, 0)
        assertEqual(#client.pending, 1)
        assertEqual(#client.pending[1], 81)
    end)

    runTest("at most two batches are outstanding: the third send waits for the oldest acknowledgement", function()
        local client, transport = newClient()
        for _ = 1, 3 do
            client:queue({ "nl" })
            client:flush()
        end
        assertEqual(table.concat(transport.log, ","), "out1,out2,wait1,out3")
    end)

    runTest("request flushes the memory (R1), carries pending entries as `pre`, and settles acknowledgements", function()
        local client, transport, memory = newClient()
        client:queue({ "c", 66 })
        client:flush()
        client:queue({ "c", 67 })
        transport.replies.get_cursor = { row = 3, column = 5 }
        local reply = client:request("get_cursor", { x = 1 })
        assertEqual(reply.row, 3)
        assertEqual(memory.flushes, 1, "R1: dirty pages published before the request")
        local request = transport.requests[1]
        assertEqual(request.op, "get_cursor")
        assertEqual(request.args.x, 1)
        assertEqual(#request.pre, 1, "the pending entry traveled with the request")
        assertEqual(request.pre[1][2], 67)
        assertEqual(table.concat(transport.log, ","), "out1,req:get_cursor,wait1", "the earlier batch was settled")
    end)

    runTest("a request with nothing pending sends no `pre`", function()
        local client, transport = newClient()
        client:request("flush")
        assertEqual(transport.requests[1].pre, nil)
    end)

    runTest("a reply that wrote RAM drops the memory's cached pages (R3); one that did not leaves them", function()
        local client, transport, memory = newClient()
        client:request("flush")
        assertEqual(memory.invalidations, 0)
        transport.replies.tokenise = { wroteRam = true }
        client:request("tokenise", {})
        assertEqual(memory.invalidations, 1)
    end)

    runTest("an acknowledgement that wrote RAM also drops the pages", function()
        local client, transport, memory = newClient()
        transport.acks[1] = { nil, true }
        client:queue({ "nl" })
        client:flush()
        client:settle()
        assertEqual(memory.invalidations, 1)
    end)

    runTest("a reply carrying an error or a fault is reported through onError", function()
        local client, transport, _, errors = newClient()
        transport.replies.stream = { error = 15, message = "Nesting stream #3 too deep" }
        client:request("stream", { n = 3 })
        assertEqual(#errors, 1)
        assertEqual(errors[1].code, 15)
        assertEqual(errors[1].message, "Nesting stream #3 too deep")

        transport.replies.bad = { fault = "boom" }
        client:request("bad")
        assertEqual(errors[2].fault, "boom")
    end)

    runTest("an acknowledgement that carries an error is reported", function()
        local client, transport, _, errors = newClient()
        transport.acks[1] = { { code = 18, message = "Print at illegal address" }, false }
        client:queue({ "s", 12345 })
        client:flush()
        client:settle()
        assertEqual(#errors, 1)
        assertEqual(errors[1].code, 18)
    end)

    runTest("during a stream 3 redirect every entry is sent at once and waited for (R7)", function()
        local client, transport = newClient()
        client:setRedirect(1)
        client:queue({ "n", 42 })
        assertEqual(#transport.requests, 1, "a request, not a queued entry")
        assertEqual(transport.requests[1].op, "flush")
        assertEqual(transport.requests[1].pre[1][2], 42)
        client:setRedirect(-1)
        client:queue({ "n", 43 })
        assertEqual(#transport.requests, 1, "asynchronous again after the redirect closes")
        client:setRedirect(-1)
        assertEqual(client.redirect, 0, "never negative")
    end)

    runTest("barrier is a request, and watched ranges include both ends", function()
        local client, transport = newClient()
        client:barrier()
        assertEqual(transport.requests[1].op, "barrier")

        client:setWatch({ { 100, 109 }, { 500, 500 } })
        assertEqual(client:isWatched(99), false)
        assertEqual(client:isWatched(100), true)
        assertEqual(client:isWatched(109), true)
        assertEqual(client:isWatched(110), false)
        assertEqual(client:isWatched(500), true)
        assertEqual(client:isWatched(501), false)
    end)

    runTest("reset and finish send pending output first, settle, then tell the service", function()
        local client, transport = newClient()
        client:queue({ "c", 65 })
        client:setRedirect(0)
        client:reset()
        assertEqual(table.concat(transport.log, ","), "out1,wait1,reset")
        assertEqual(client.redirect, 0)

        client:queue({ "c", 66 })
        client:finish("quit")
        assertEqual(table.concat(transport.log, ","), "out1,wait1,reset,out2,wait2,finish:quit")
    end)

    runTest("config goes straight to the transport", function()
        local client, transport = newClient()
        assertEqual(client:config({ pageSize = 762 }).ok, true)
        assertEqual(transport.log[1], "config")
    end)

    runTest("the loopback transport calls a service directly", function()
        local calls: { string } = {}
        local service: any = {}
        function service:out(entries: any)
            table.insert(calls, "out:" .. #entries)
            return nil, true
        end
        function service:request(op: string, args: any, pre: any)
            table.insert(calls, "request:" .. op)
            return { value = 7 }
        end
        function service:config(cfg: any)
            table.insert(calls, "config")
            return { ok = true }
        end
        function service:reset()
            table.insert(calls, "reset")
        end
        function service:finish(reason: string, err: any)
            table.insert(calls, "finish:" .. reason)
        end

        local memory = newMemory()
        local client = ZTextClient.new(ZTextClient.loopback(service), memory)
        client:queue({ "nl" })
        client:flush()
        assertEqual(client:request("check_unicode", { c = 65 }).value, 7)
        client:config({})
        client:reset()
        client:finish("quit")
        assertEqual(table.concat(calls, ","), "out:1,request:check_unicode,config,reset,finish:quit")
        assertEqual(memory.invalidations, 1, "the batch's acknowledgement wrote RAM")
    end)

    TestFramework.printSummary("Text client tests")
end

print(`Starting Memory: {ll.GetFreeMemory()} bytes`)

CoroutineMgr:create_task(runAllTests)
