---------------------------------------------------------------------
-- Probes LinksetData behaviour relevant to paging VM RAM out to it:
-- binary safety, size limits, accounting, speed, events, persistence.
-- All keys use the "zprobe" prefix and are deleted at the end, except a
-- run counter that shows whether data survives a script reset.
---------------------------------------------------------------------

local CoroutineMgr, _, yield_frame = table.unpack(require("../VM/coromgr.luau"))

local PREFIX = "zprobe"
local events = 0
local keysWritten: {string} = {}

local function write(key: string, value: string): number
    local status = ll.LinksetDataWrite(key, value)
    table.insert(keysWritten, key)
    return status
end

local function bytesString(length: number): string
    local chars = {}
    for i = 1, length do
        chars[i] = string.char((i - 1) % 256)
    end
    return table.concat(chars)
end

local function run()
    LLEvents:on("linkset_data", function()
        events += 1
    end)

    print(`Available before: {ll.LinksetDataAvailable()} bytes, keys: {ll.LinksetDataCountKeys()}`)

    -- Persistence across script resets: reset the script and run again.
    local runs = tonumber(ll.LinksetDataRead(PREFIX .. "_runs")) or 0
    ll.LinksetDataWrite(PREFIX .. "_runs", tostring(runs + 1))
    print(`Persistence: this is run {runs + 1} (data from earlier runs {runs > 0 and "SURVIVED" or "not seen"})`)

    -- 1. Raw bytes 0..255 (including NUL), as a string value.
    local raw = bytesString(256)
    local status = write(PREFIX .. "_raw", raw)
    local back = ll.LinksetDataRead(PREFIX .. "_raw")
    local firstDiff = 0
    for i = 1, math.max(#raw, #back) do
        if string.byte(raw, i) ~= string.byte(back, i) then
            firstDiff = i
            break
        end
    end
    print(`Binary: status {status}, wrote {#raw} bytes, read {#back}, {firstDiff == 0 and "identical" or `first difference at byte {firstDiff}`}`)

    -- 2. A 256-byte buffer through Base64.
    local buf = buffer.create(256)
    for i = 0, 255 do
        buffer.writeu8(buf, i, (i * 7 + 3) % 256)
    end
    local encoded = llbase64.encode(buf)
    status = write(PREFIX .. "_b64", encoded)
    local decoded = llbase64.decode(ll.LinksetDataRead(PREFIX .. "_b64"), true)
    local same = buffer.tostring(buf) == buffer.tostring(decoded)
    print(`Base64: status {status}, {#encoded} chars, round trip {same and "ok" or "MISMATCH"}`)

    -- 3. Value size limits (Base64-shaped text), and what each costs.
    for _, length in { 344, 688, 1024, 1368, 2048, 4096, 8192, 16384 } do
        local before = ll.LinksetDataAvailable()
        local key = `{PREFIX}_v{length}`
        local ok, result = pcall(write, key, string.rep("A", length))
        local readBack = ok and #ll.LinksetDataRead(key) or -1
        print(`Value {length}: {ok and `status {result}` or `error {result}`}, read back {readBack}, `
            .. `available {before} -> {ll.LinksetDataAvailable()}`)
    end

    -- 4. Key length limits.
    for _, length in { 16, 64, 255, 1024 } do
        local key = PREFIX .. string.rep("k", length)
        local ok, result = pcall(write, key, "x")
        print(`Key {#key}: {ok and `status {result}` or `error {result}`}`)
    end

    -- 5. Speed: 400 write+read cycles of a 344-character value, plus decode.
    local value = string.rep("A", 344)
    local n = 400
    local t0 = ll.GetTime()
    for i = 1, n do
        ll.LinksetDataWrite(PREFIX .. "_speed", value)
    end
    local t1 = ll.GetTime()
    for i = 1, n do
        local _ = ll.LinksetDataRead(PREFIX .. "_speed")
    end
    local t2 = ll.GetTime()
    for i = 1, n do
        local _ = llbase64.decode(encoded, true)
    end
    local t3 = ll.GetTime()
    for i = 1, n do
        local _ = llbase64.encode(buf)
    end
    local t4 = ll.GetTime()
    table.insert(keysWritten, PREFIX .. "_speed")
    print(`Speed per call (microseconds): write {(t1 - t0) / n * 1e6}, read {(t2 - t1) / n * 1e6}, `
        .. `decode {(t3 - t2) / n * 1e6}, encode {(t4 - t3) / n * 1e6}`)

    -- 6. Events: each write above should have raised linkset_data.
    yield_frame(1)
    print(`linkset_data events received by this script: {events}`)

    -- Cleanup.
    for _, key in keysWritten do
        ll.LinksetDataDelete(key)
    end
    print(`Available after cleanup: {ll.LinksetDataAvailable()} bytes, keys: {ll.LinksetDataCountKeys()}`)
end

CoroutineMgr:create_task(run)
