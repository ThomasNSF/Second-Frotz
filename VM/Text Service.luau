---------------------------------------------------------------------
-- The Text Service script: everything the player sees and types.
--
-- Put this script in the same prim as the core VM script and the Memory
-- Manager. It waits for the core's TS_CONFIG, attaches to the story's
-- memory (RAM pages through LinksetData, ROM pages from the Memory
-- Manager), and then prints the core's output and reads the owner's chat
-- as the game's input. See docs/TEXT_SERVICE.md.
--
-- To use another front end, replace ChatHost here with any other ZHost.
---------------------------------------------------------------------

local ZMemory = require("ZMemory.luau")
local ChatHost = require("ChatHost.luau")
local TextService = require("TextService.luau")
local TextServiceLink = require("TextServiceLink.luau")

local host = ChatHost.new()

local service = TextService.new(host, ZMemory.new())
local link = TextServiceLink.new(service, function(channel: number, text: string, id: string)
    ll.MessageLinked(LINK_THIS, channel, text, id)
end, { idleSeconds = 1 })

link:start()
link:hello()

print(`Text Service ready. Free memory: {ll.GetFreeMemory()} bytes`)
