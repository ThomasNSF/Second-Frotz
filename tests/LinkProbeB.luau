---------------------------------------------------------------------
-- Second half of the link-message probe: the echo side. Put this script
-- and LinkProbeA in the SAME prim, reset both, and read the results in
-- LinkProbeA's output. This script prints nothing of its own except a
-- startup line.
--
-- It listens on channel 9101 and answers on 9102, so neither script
-- hears its own messages. Messages look like "KIND|payload".
---------------------------------------------------------------------

local TO_B, FROM_B = 9101, 9102

local burstCount = 0
local burstGaps = 0
local burstLast = 0
local burstOutOfOrder = 0

local function reply(text: string)
    ll.MessageLinked(LINK_THIS, FROM_B, text, "")
end

LLEvents:on("link_message", function(_sender: number, channel: number, str: string, _id: any)
    if channel ~= TO_B then
        return
    end
    local bar = string.find(str, "|", 1, true)
    local kind = if bar then string.sub(str, 1, bar - 1) else str
    local payload = if bar then string.sub(str, bar + 1) else ""

    if kind == "PING" then
        reply("PONG|" .. payload)
    elseif kind == "SIZE" then
        reply(`SIZE|{#str}`)
    elseif kind == "BURSTSTART" then
        burstCount, burstGaps, burstLast, burstOutOfOrder = 0, 0, 0, 0
        reply("READY")
    elseif kind == "B" then
        local n = tonumber(payload) or 0
        burstCount += 1
        if n < burstLast then
            burstOutOfOrder += 1
        elseif n ~= burstLast + 1 then
            burstGaps += 1
        end
        burstLast = n
    elseif kind == "BURSTREPORT" then
        reply(`BURST|{burstCount}|{burstGaps}|{burstOutOfOrder}|{burstLast}`)
    elseif kind == "LSDREAD" then
        -- payload = key, then the value A wrote there, split by a second bar.
        local split = string.find(payload, "|", 1, true) or #payload + 1
        local key = string.sub(payload, 1, split - 1)
        local expected = string.sub(payload, split + 1)
        local seen = ll.LinksetDataRead(key)
        ll.LinksetDataWrite(key .. "_b", "from B " .. expected)
        reply(`LSD|{if seen == expected then "match" else "MISMATCH, B read '" .. seen .. "'"}`)
    end
end)

print("LinkProbeB ready on channel 9101")
