---------------------------------------------------------------------
-- Memory manager protocol constants shared by the VM and memory
-- manager scripts.
---------------------------------------------------------------------

export type MemoryAPI = {
    MEMORY_CHANNEL: number,
    LOAD_CARD: string,
    LOAD_CARD_RES: string,
    PAGE_REQ: string,
    PAGE_RES: string,
    HEADER_REQ: string,
    HEADER_RES: string,
}

return {
    MEMORY_CHANNEL = 9000,
    LOAD_CARD = "LOAD_CARD",
    LOAD_CARD_RES = "LOAD_CARD_RES",
    PAGE_REQ = "PAGE_REQ",
    PAGE_RES = "PAGE_RES",
    HEADER_REQ = "HEADER_REQ",
    HEADER_RES = "HEADER_RES",
}
