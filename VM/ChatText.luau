---------------------------------------------------------------------
-- Splits text into pieces that fit in one chat message.
--
-- Pure string logic with no Second Life calls, so it can be tested on
-- its own. llSay accepts at most 1024 bytes per message and silently
-- cuts the rest, so ChatHost sends the pieces this returns.
---------------------------------------------------------------------

local ChatText = {}

-- Default message size: the llSay limit, in bytes (not characters).
ChatText.MAX_BYTES = 1024

-- Splits `text` into pieces of at most `maxBytes` bytes. A piece ends at
-- the last newline within the limit, else the last space; that separator
-- is dropped. A run with no separator is cut at the limit, moved back so
-- a multibyte UTF-8 character is never split. Pieces are never empty.
function ChatText.split(text: string, maxBytes: number): {string}
    assert(maxBytes >= 4, "maxBytes must hold at least one UTF-8 character")

    local pieces: {string} = {}
    local rest = text
    while #rest > maxBytes do
        local cut: number? = nil  -- last byte kept in this piece
        local skip = 0            -- separator bytes dropped after it

        -- The byte just past the limit may itself be the separator, so
        -- the scan starts one beyond it. Index 1 is excluded to keep the
        -- piece non-empty.
        for _, separator in { 10, 32 } do
            for i = maxBytes + 1, 2, -1 do
                if string.byte(rest, i) == separator then
                    cut, skip = i - 1, 1
                    break
                end
            end
            if cut then
                break
            end
        end

        if not cut then
            cut = maxBytes
            -- Back up while the next byte is a continuation byte, which
            -- would leave the character split between two pieces.
            while cut > 1 do
                local nextByte = string.byte(rest, cut + 1)
                if nextByte < 0x80 or nextByte >= 0xC0 then
                    break
                end
                cut -= 1
            end
        end

        table.insert(pieces, string.sub(rest, 1, cut))
        rest = string.sub(rest, cut + 1 + skip)
    end

    if #rest > 0 then
        table.insert(pieces, rest)
    end
    return pieces
end

return ChatText
