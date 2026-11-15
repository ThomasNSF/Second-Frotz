---------------------------------------------------------------------
-- Finds where the viewer cuts off long chat lines, to choose the chunk
-- size for ChatHost. Says one message per second on channel 0, each
-- exactly N characters long, starting with "[N]" and ending with "<END>".
-- A "|" marks every 50th character, and the digit before it is the
-- position's last digit, so you can read off where a cut happened.
--
-- Look in the chat window (not the script console) and note, for each
-- message, whether "<END>" is visible and where the text stopped.
-- Then a few extra cases: multibyte characters, embedded newlines, and a
-- message right at 1024 bytes.
---------------------------------------------------------------------

local CoroutineMgr, _, yield_frame = table.unpack(require("../VM/coromgr.luau"))

local LENGTHS = { 100, 200, 254, 255, 256, 257, 300, 400, 512, 1000, 1024 }

-- A message of exactly `length` ASCII characters.
local function makeMessage(length: number): string
    local head = `[{length}]`
    local tail = "<END>"
    local chars = {}
    for position = #head + 1, length - #tail do
        chars[#chars + 1] = if position % 50 == 0 then "|" else tostring(position % 10)
    end
    return head .. table.concat(chars) .. tail
end

local function say(label: string, text: string)
    print(`{label}: {utf8.len(text) or "?"} characters, {#text} bytes`)
    ll.Say(0, text)
    yield_frame(1)
end

local function run()
    print("ChatProbe: watch the chat window. One message per second.")
    for _, length in LENGTHS do
        local text = makeMessage(length)
        say(`ASCII {length}`, text)
    end

    -- 300 two-byte characters (600 bytes), ending in a marker.
    say("two-byte characters", "[300 x e-acute]" .. string.rep(utf8.char(0xE9), 285) .. "<END>")

    -- Three lines in one message, each short.
    say("embedded newlines", "[3 lines]\nsecond line\nthird line <END>")

    -- Long message made of short lines (is the cutoff per message or per line?).
    local lines = {}
    for i = 1, 20 do
        lines[i] = string.format("line %02d: the quick brown fox jumps over the lazy dog", i)
    end
    lines[#lines + 1] = "<END>"
    say("20 lines, about 1000 bytes", table.concat(lines, "\n"))

    print("ChatProbe done.")
end

CoroutineMgr:create_task(run)
