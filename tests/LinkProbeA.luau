---------------------------------------------------------------------
-- Link-message probe, driver side. Put this script and LinkProbeB in the
-- SAME prim, reset LinkProbeB first and then this one. Measures what the
-- Text Service design relies on:
--   1. round-trip time for a request and its reply,
--   2. how many back-to-back messages arrive (queue overflow) and
--      whether they arrive in order,
--   3. the largest message that arrives intact,
--   4. whether a LinksetData write by one script is seen at once by the
--      other, in both directions.
--
-- Messages to B use channel 9101 and replies come back on 9102.
---------------------------------------------------------------------

local CoroMgr, await_event, yield_frame = table.unpack(require("../VM/coromgr.luau"))

local TO_B, FROM_B = 9101, 9102
local WAIT = 5  -- seconds to wait for a reply before calling it lost

LLEvents:on("link_message", function(_sender: number, channel: number, str: string, _id: any)
    if channel == FROM_B then
        CoroMgr:handle_event("reply", true, str)
    end
end)

local function send(text: string)
    ll.MessageLinked(LINK_THIS, TO_B, text, "")
end

-- Sends a request and waits for B's reply. Returns the reply or nil.
local function ask(text: string): string?
    send(text)
    local ok, reply = await_event("reply", WAIT)
    if ok and typeof(reply) == "string" then
        return reply
    end
    return nil
end

local function run()
    print("LinkProbeA: starting")

    -- 1. Round trips.
    local count = 40
    local total, shortest, longest = 0, math.huge, 0
    local lost = 0
    for i = 1, count do
        local t0 = ll.GetTime()
        local reply = ask("PING|" .. i)
        local dt = ll.GetTime() - t0
        if reply == "PONG|" .. i then
            total += dt
            shortest = math.min(shortest, dt)
            longest = math.max(longest, dt)
        else
            lost += 1
        end
    end
    local answered = count - lost
    if answered > 0 then
        print(`Round trip over {answered} pings: average {math.floor(total / answered * 1000)} ms, `
            .. `shortest {math.floor(shortest * 1000)} ms, longest {math.floor(longest * 1000)} ms, lost {lost}`)
    else
        print("Round trip: no reply from LinkProbeB. Is it in this prim and running?")
        return
    end

    -- 2. Bursts of back-to-back messages.
    for _, size in { 16, 32, 64, 100, 200 } do
        ask("BURSTSTART")
        for i = 1, size do
            send("B|" .. i)
        end
        yield_frame(1.5)  -- let B drain its queue
        local report = ask("BURSTREPORT")
        if report then
            local received, gaps, outOfOrder, last = string.match(report, "BURST|(%d+)|(%d+)|(%d+)|(%d+)")
            print(`Burst of {size}: B received {received}, gaps {gaps}, out of order {outOfOrder}, last {last}`)
        else
            print(`Burst of {size}: no report from B`)
        end
    end

    -- 3. Message sizes.
    for _, length in { 256, 512, 1000, 1024, 1500, 2048, 4096, 8192 } do
        local text = "SIZE|" .. string.rep("x", length - 5)
        local ok, reply = pcall(ask, text)
        if not ok then
            print(`Size {length}: send failed: {reply}`)
        elseif reply then
            local arrived = tonumber(string.match(reply, "SIZE|(%d+)")) or -1
            print(`Size {length}: B saw {arrived} characters {arrived == length and "(intact)" or "(CHANGED)"}`)
        else
            print(`Size {length}: no reply (dropped?)`)
        end
    end

    -- 4. LinksetData visibility in both directions.
    local key, value = "lprobe_a", "written by A at " .. tostring(ll.GetTime())
    ll.LinksetDataWrite(key, value)
    local reply = ask(`LSDREAD|{key}|{value}`)
    print("LinksetData A to B: " .. (reply or "no reply"))
    local back = ll.LinksetDataRead(key .. "_b")
    print("LinksetData B to A: " .. (if back == "from B " .. value then "match" else `MISMATCH, A read '{back}'`))
    ll.LinksetDataDelete(key)
    ll.LinksetDataDelete(key .. "_b")

    print("LinkProbeA: done")
end

CoroMgr:create_task(run)
