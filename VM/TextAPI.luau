---------------------------------------------------------------------
-- Text Service protocol constants shared by the core VM script and the
-- Text Service script. See docs/TEXT_SERVICE.md for the messages.
---------------------------------------------------------------------

export type TextAPI = {
    TEXT_CHANNEL: number,
    TEXT_REPLY_CHANNEL: number,
    PROTOCOL_VERSION: number,
    TS_HELLO: string,
    TS_CONFIG: string,
    TS_CONFIG_RES: string,
    TS_OUT: string,
    TS_ACK: string,
    TS_REQ: string,
    TS_RES: string,
    TS_RESET: string,
    TS_END: string,
}

return {
    -- Core to Text Service. Replies travel on a second channel so that
    -- neither script has to look at (or decode) its own messages, which a
    -- link message sent to LINK_THIS also delivers back to the sender.
    TEXT_CHANNEL = 9001,
    TEXT_REPLY_CHANNEL = 9002,
    PROTOCOL_VERSION = 1,

    -- Text Service to core.
    TS_HELLO = "TS_HELLO",
    TS_CONFIG_RES = "TS_CONFIG_RES",
    TS_ACK = "TS_ACK",
    TS_RES = "TS_RES",

    -- Core to Text Service.
    TS_CONFIG = "TS_CONFIG",
    TS_OUT = "TS_OUT",
    TS_REQ = "TS_REQ",
    TS_RESET = "TS_RESET",
    TS_END = "TS_END",
}
