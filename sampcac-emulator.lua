--[[
SAMPCAC v0.10 emulator by 1therealcloud

GitHub:
https://github.com/1therealcloud/
]]
script_name("SAMPCAC Emulator")
script_author("1therealcloud")

require("sampfuncs")
require("samp.raknet")

local base64 = require("base64") -- for hwid

local bit = require("bit")
local ffi = require("ffi")

local RPC_HELLO                 = 180 -- B4
local RPC_CHEAT_REPORT          = 181 -- B5
local RPC_RESOURCE_MISMATCH     = 182 -- B6
local RPC_CHALLENGE_REPLY       = 183 -- B7
local RPC_SCREENSHOT            = 184 -- B8
local RPC_MEMORY_REPLY          = 185 -- B9
local RPC_GAME_OPTION           = 186 -- BA
local RPC_CHALLENGE             = 187 -- BB
local RPC_GLITCH_SETTING        = 188 -- BC
local RPC_MEMORY                = 189 -- BD
local RPC_RESOURCE_CONFIG       = 190 -- BE
local RPC_HELLO_ACK             = 191 -- BF

ffi.cdef[[
    void* __stdcall GetCurrentProcess(void);
    int __stdcall ReadProcessMemory(void* process, const void* address, void* buffer, size_t size, size_t* bytes_read);
]]

local kernel32 = ffi.load("kernel32") -- load kernel32
local process = kernel32.GetCurrentProcess() -- get game process
local read_buffer = ffi.new("uint8_t[4]") -- read memory rpc buffer
local bytes_read = ffi.new("size_t[1]") -- another fuckin' buffer

local hwid = nil

-- generate random HWID
local function new_hwid()
    local bytes = {}

    for i = 1, 16 do
        bytes[i] = string.char(math.random(0, 255))
    end

    return base64.encode(table.concat(bytes))
end

-- make challenge reply
local function makeChallengeReply(bs)
    local HEADER_SIZE = 13 -- header size

    -- validate bits
    local total_bits = raknetBitStreamGetNumberOfBitsUsed(bs)
    if total_bits < 120 or total_bits > 176 or total_bits % 8 ~= 0 then
        return nil, nil
    end

    -- read header
    raknetBitStreamResetReadPointer(bs)
    local bytes = {}
    for i = 0, HEADER_SIZE - 1 do
        bytes[i] = bit.band(raknetBitStreamReadInt8(bs), 0xFF)
    end

    -- read params
    local length = bit.band(raknetBitStreamReadInt8(bs), 0xFF) -- enter length value
    local key = bit.band(raknetBitStreamReadInt8(bs), 0xFF)

    if length < 13 or length > 20 or total_bits ~= (length + 2) * 8 or key >= length then
        return nil, nil
    end

    -- read remaining bytes in reverse
    for i = length - 1, HEADER_SIZE, -1 do
        bytes[i] = bit.band(raknetBitStreamReadInt8(bs), 0xFF)
    end

    -- decrypt
    for i = 0, length - 1 do
        local x = bit.bxor(math.floor(length / 2) + i, 0xAC) % length
        local y = (key + bytes[x]) % length
        bytes[i] = bit.bxor(bytes[i], bytes[y])
    end

    return bytes, length
end

-- safe read client memory
local function readMemory(address, size)

    -- return nil if error
    if size == 0 or address == 0 or address + size > 0x100000000 then return nil end

    -- read bytes by ffi
    bytes_read[0] = 0
    local ptr = ffi.cast("const void*", ffi.cast("uintptr_t", address))
    local result = kernel32.ReadProcessMemory(process, ptr, read_buffer, size, bytes_read)

    -- return nil if error
    if result == 0 or tonumber(bytes_read[0]) ~= size then
        return nil
    end

    return ffi.string(read_buffer, size)
end



-- hook send RPC
function onSendRpc(id)
    if id ~= RPC_CLIENTJOIN then return end

    local bs = raknetNewBitStream()

    raknetBitStreamWriteInt16(bs, 0x0CAC) -- magic const
    raknetBitStreamWriteInt8(bs, 0)
    raknetBitStreamWriteInt16(bs, 10)
    raknetBitStreamWriteInt8(bs, 0)
    raknetBitStreamWriteInt8(bs, #hwid + 1)

    for i = 1, #hwid do
        raknetBitStreamWriteInt8(bs, hwid:byte(i))
    end

    raknetBitStreamWriteInt8(bs, 0)

    raknetSendRpcEx(RPC_HELLO, bs, HIGH_PRIORITY, RELIABLE_ORDERED, 0, false) -- RELIABLE_SEQUENCED (after)
    raknetDeleteBitStream(bs)
end

-- RegisterAsRemoteProcedureCall
function onReceiveRpc(id, bs)
    -- handle challenge rpc
    if id == RPC_CHALLENGE then
        local bytes, length = makeChallengeReply(bs)
        
        if not bytes then return end

        local bs = raknetNewBitStream()
        raknetBitStreamWriteInt32(bs, 0)

        for i = 0, length - 1 do
            raknetBitStreamWriteInt8(bs, bytes[i])
        end

        raknetSendRpcEx(RPC_CHALLENGE_REPLY, bs, HIGH_PRIORITY, RELIABLE_ORDERED, 0, false)
        raknetDeleteBitStream(bs)

        -- do not send rpc to the game
        return false
    end

    -- handle read memory rpc
    if id == RPC_MEMORY then

        if raknetBitStreamGetNumberOfBitsUsed(bs) ~= 64 then return end

        raknetBitStreamResetReadPointer(bs)
        local address = tonumber(ffi.cast("uint32_t", raknetBitStreamReadInt32(bs)))
        local size = tonumber(ffi.cast("uint32_t", raknetBitStreamReadInt32(bs)))

        if size > 4 then return end

        local data = readMemory(address, size)
        if not data then return end

        local bs = raknetNewBitStream()
        raknetBitStreamWriteInt32(bs, address)
        raknetBitStreamWriteInt8(bs, size)

        for i = 1, #data do
            raknetBitStreamWriteInt8(bs, data:byte(i))
        end

        raknetSendRpcEx(RPC_MEMORY_REPLY, bs, HIGH_PRIORITY, RELIABLE_SEQUENCED, 0, false)
        raknetDeleteBitStream(bs)

        -- do not send rpc to the game
        return false
    end
end

function main()
    -- generate random seed
    math.randomseed(os.time())

    -- generate random hwid
    hwid = new_hwid()

    print(thisScript().name .. " by " .. thisScript().authors[1] .. " Loaded!")
    wait(-1)
end
