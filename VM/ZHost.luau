---------------------------------------------------------------------
-- The interface between the VM driver and whatever shows the story to
-- the player and collects their input. ChatHost (public chat) is the
-- first implementation; a HUD or web front end would be another.
--
-- A host is a table of methods called with colon syntax. The five
-- required methods are the minimum to play a story. Capabilities are
-- optional: when a host lacks one, the matching opcode takes the
-- plain-text default described in PHASE5_PLAN.md (screen opcodes are
-- ignored, get_cursor stores 1,1, set_font stores 0).
--
-- readLine and readChar run in the VM coroutine and may yield until the
-- player responds.
---------------------------------------------------------------------

export type ZHost = {
    -- Required.
    write: (ZHost, string) -> (),
    -- (maxLength, timeout in tenths of a second or nil) -> (text, timedOut).
    -- On a timeout the text is empty and timedOut is true.
    readLine: (ZHost, number, number?) -> (string, boolean),
    readChar: (ZHost, number?) -> (string, boolean),
    fatal: (ZHost, any) -> (),
    quit: (ZHost) -> (),

    -- Optional capabilities.
    splitWindow: ((ZHost, number) -> ())?,
    setWindow: ((ZHost, number) -> ())?,
    eraseWindow: ((ZHost, number) -> ())?,
    eraseLine: ((ZHost, number) -> ())?,
    setCursor: ((ZHost, number, number) -> ())?,
    getCursor: ((ZHost) -> (number, number))?,
    setTextStyle: ((ZHost, number) -> ())?,
    setColour: ((ZHost, number, number) -> ())?,
    -- Returns the previous font, or 0 if the font is not available.
    setFont: ((ZHost, number) -> number)?,
    statusLine: ((ZHost, string, number, number, boolean) -> ())?,
}

local ZHost = {}

local REQUIRED = { "write", "readLine", "readChar", "fatal", "quit" }

-- Raises an error naming the first required method a host is missing.
function ZHost.validate(host: any): ()
    assert(typeof(host) == "table", "a host must be a table")
    for _, name in REQUIRED do
        assert(typeof(host[name]) == "function", "host is missing required method: " .. name)
    end
end

return ZHost
