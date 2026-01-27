-- CC:Tweaked Video Player v2.8
-- Simple, reliable playback

local VERSION = "2.8"

-- Auto-install Pixelbox
if not fs.exists("pixelbox_lite.lua") then
    print("Installing Pixelbox Lite...")
    shell.run("wget", "https://raw.githubusercontent.com/9551-Dev/pixelbox_lite/master/pixelbox_lite.lua")
end

local box = require("pixelbox_lite").new(term.current())

-- Find speaker
local speaker = peripheral.find("speaker")
print(speaker and ("Speaker: " .. peripheral.getName(speaker)) or "No speaker")

-- DFPWM decoder
local dfpwm = nil
pcall(function() 
    dfpwm = require("cc.audio.dfpwm") 
end)
print(dfpwm and "DFPWM: OK" or "DFPWM: not found")

-- Utilities
local function readU32(data, pos)
    return data:byte(pos) + data:byte(pos + 1) * 256 + 
           data:byte(pos + 2) * 65536 + data:byte(pos + 3) * 16777216
end

local function readU16(data, pos)
    return data:byte(pos) + data:byte(pos + 1) * 256
end

local function httpGet(url, binary)
    local response = http.get(url, nil, binary)
    if response then
        local data = response.readAll()
        response.close()
        return data
    end
    return nil
end

local function httpGetJSON(url)
    local data = httpGet(url, false)
    return data and textutils.unserializeJSON(data)
end

-- RLE Decompressor
local function decompressRLE(data)
    local result = {}
    local i = 1
    
    while i <= #data do
        local header = data:byte(i)
        i = i + 1
        
        if bit32.band(header, 0x80) ~= 0 then
            local count = bit32.band(header, 0x7F) + 1
            local value = data:byte(i)
            i = i + 1
            for j = 1, count do
                result[#result + 1] = value
            end
        else
            local count = bit32.band(header, 0x7F) + 1
            for j = 1, count do
                result[#result + 1] = data:byte(i)
                i = i + 1
            end
        end
    end
    
    return result
end

-- Frame Decoder
local decoder = {
    palette = {},
    prevFrame = nil,
}

function decoder:init()
    self.palette = {}
    self.prevFrame = nil
    for i = 1, 16 do 
        self.palette[i] = {0, 0, 0} 
    end
end

function decoder:decode(data)
    local pos = 1
    local header = data:byte(pos)
    pos = pos + 1
    
    local hasPalette = bit32.band(header, 0x01) ~= 0
    local isDelta = bit32.band(header, 0x02) ~= 0
    
    if hasPalette then
        for i = 1, 16 do
            self.palette[i] = {
                data:byte(pos),
                data:byte(pos + 1),
                data:byte(pos + 2)
            }
            pos = pos + 3
        end
    end
    
    local dataSize = readU16(data, pos)
    pos = pos + 2
    
    local pixels = decompressRLE(data:sub(pos, pos + dataSize - 1))
    
    local frame = {}
    if isDelta and self.prevFrame then
        for i = 1, #pixels do
            if bit32.band(pixels[i], 0x10) ~= 0 then
                frame[i] = bit32.band(pixels[i], 0x0F)
            else
                frame[i] = self.prevFrame[i] or 0
            end
        end
    else
        for i = 1, #pixels do
            frame[i] = bit32.band(pixels[i], 0x0F)
        end
    end
    
    self.prevFrame = frame
    return frame
end

function decoder:applyPalette()
    for i = 1, 16 do
        local c = self.palette[i]
        term.setPaletteColor(2^(i-1), c[1]/255, c[2]/255, c[3]/255)
    end
end

-- Segment loader
local segmentCache = {}

local function loadSegment(url, index)
    if segmentCache[index] then 
        return segmentCache[index] 
    end
    
    local data = httpGet(url, true)
    if not data or data:sub(1, 4) ~= "CCV1" then 
        return nil 
    end
    
    local frameCount = readU32(data, 5)
    local frames = {}
    local pos = 9
    
    for i = 1, frameCount do
        if pos > #data then break end
        
        local frameSize = readU32(data, pos)
        pos = pos + 4
        local frameData = data:sub(pos, pos + frameSize - 1)
        pos = pos + frameSize
        
        local audioSize = readU16(data, pos)
        pos = pos + 2
        local audioData = audioSize > 0 and data:sub(pos, pos + audioSize - 1) or nil
        pos = pos + audioSize
        
        frames[i] = { video = frameData, audio = audioData }
    end
    
    segmentCache[index] = { frames = frames }
    
    -- Limit cache
    local count = 0
    for k in pairs(segmentCache) do 
        count = count + 1 
    end
    if count > 3 then
        for k in pairs(segmentCache) do
            if k ~= index then
                segmentCache[k] = nil
                break
            end
        end
    end
    
    return segmentCache[index]
end

-- Audio player using native DFPWM
local audioDecoder = dfpwm and dfpwm.make_decoder() or nil

local function playAudio(data)
    if not speaker or not data or #data == 0 then
        return
    end
    
    if audioDecoder then
        local samples = audioDecoder(data)
        if samples then
            -- Non-blocking play
            speaker.playAudio(samples)
        end
    end
end

-- Player
local function play(url)
    -- Load metadata
    local baseUrl, meta
    
    if url:match("meta%.json$") then
        baseUrl = url:gsub("/meta%.json$", "")
        meta = httpGetJSON(url)
    elseif url:match("manifest%.json$") then
        meta = httpGetJSON(url)
        baseUrl = url:gsub("/manifest%.json$", "")
    else
        baseUrl = url
        meta = httpGetJSON(baseUrl .. "/meta.json")
    end
    
    if not meta then
        print("Failed to load metadata!")
        return false
    end
    
    print(string.format("Video: %dx%d @ %.1ffps", meta.width, meta.height, meta.fps))
    print(string.format("Duration: %.1fs, Frames: %d", meta.duration, meta.total_frames))
    print(string.format("Audio: %s", meta.has_audio and "Yes" or "No"))
    if meta.volume then
        print(string.format("Volume: %.0f%%", meta.volume * 100))
    end
    print()
    print("Press any key to start...")
    os.pullEvent("key")
    
    -- Init
    decoder:init()
    segmentCache = {}
    
    local frameTime = 1 / meta.fps
    local segmentIndex = 0
    local frameIndex = 1
    local globalFrame = 0
    local playing = true
    local paused = false
    
    -- Load first segment
    local function getSegmentUrl(idx)
        local seg = meta.segments[idx + 1]
        return seg and seg.url or string.format("%s/seg_%04d.ccv", baseUrl, idx)
    end
    
    local segment = loadSegment(getSegmentUrl(0), 0)
    if not segment then
        print("Failed to load first segment!")
        return false
    end
    
    -- Pre-buffer next
    if #meta.segments > 1 then
        loadSegment(getSegmentUrl(1), 1)
    end
    
    local lastTime = os.clock()
    local accumulator = 0
    
    while playing do
        local now = os.clock()
        local dt = now - lastTime
        lastTime = now
        
        if not paused then
            accumulator = accumulator + dt
            
            -- Process frames
            while accumulator >= frameTime and playing do
                accumulator = accumulator - frameTime
                
                -- Need next segment?
                if frameIndex > #segment.frames then
                    segmentIndex = segmentIndex + 1
                    
                    if segmentIndex >= #meta.segments then
                        playing = false
                        break
                    end
                    
                    segment = segmentCache[segmentIndex]
                    if not segment then
                        segment = loadSegment(getSegmentUrl(segmentIndex), segmentIndex)
                        if not segment then
                            playing = false
                            break
                        end
                    end
                    
                    frameIndex = 1
                    
                    -- Pre-buffer
                    local nextIdx = segmentIndex + 1
                    if nextIdx < #meta.segments and not segmentCache[nextIdx] then
                        loadSegment(getSegmentUrl(nextIdx), nextIdx)
                    end
                end
                
                -- Process frame
                local frameData = segment.frames[frameIndex]
                if frameData then
                    -- Video
                    local pixels = decoder:decode(frameData.video)
                    decoder:applyPalette()
                    
                    -- Render
                    local w = meta.width
                    local bw = math.min(w, box.width)
                    local bh = math.min(meta.height, box.height)
                    
                    for y = 1, bh do
                        local row = box.canvas[y]
                        local yOffset = (y - 1) * w
                        for x = 1, bw do
                            row[x] = 2 ^ (pixels[yOffset + x] or 0)
                        end
                    end
                    box:render()
                    
                    -- Audio
                    if frameData.audio then
                        playAudio(frameData.audio)
                    end
                    
                    -- Status bar
                    local sw, sh = term.getSize()
                    term.setCursorPos(1, sh)
                    term.setBackgroundColor(colors.gray)
                    term.setTextColor(colors.white)
                    term.clearLine()
                    
                    local progress = globalFrame / meta.total_frames
                    local barW = sw - 15
                    local filled = math.floor(progress * barW)
                    
                    term.write(" \16 [")
                    term.write(string.rep("=", filled))
                    term.write(string.rep("-", barW - filled))
                    term.write("] ")
                    
                    local t = globalFrame / meta.fps
                    term.write(string.format("%d:%02d", math.floor(t/60), math.floor(t%60)))
                    
                    term.setBackgroundColor(colors.black)
                end
                
                frameIndex = frameIndex + 1
                globalFrame = globalFrame + 1
                
                if globalFrame >= meta.total_frames then
                    playing = false
                    break
                end
            end
        else
            -- Paused indicator
            local sw, sh = term.getSize()
            term.setCursorPos(1, sh)
            term.setBackgroundColor(colors.gray)
            term.setTextColor(colors.white)
            term.clearLine()
            term.write(" || PAUSED - Space to resume, Q to quit")
            term.setBackgroundColor(colors.black)
        end
        
        -- Input
        local timer = os.startTimer(0.01)
        while true do
            local event, p1 = os.pullEvent()
            
            if event == "timer" and p1 == timer then
                break
            elseif event == "key" then
                if p1 == keys.space then
                    paused = not paused
                    if not paused then
                        lastTime = os.clock()
                        accumulator = 0
                    end
                elseif p1 == keys.q or p1 == keys.escape then
                    playing = false
                    break
                end
            elseif event == "speaker_audio_empty" then
                -- Audio buffer ready
            end
        end
    end
    
    -- Reset palette
    for i = 0, 15 do
        term.setPaletteColor(2^i, term.nativePaletteColor(2^i))
    end
    
    return true
end

-- Main
local function main(args)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    
    term.setTextColor(colors.cyan)
    print("=== CC Video Player v" .. VERSION .. " ===")
    print()
    
    local url = args[1]
    
    if not url then
        term.setTextColor(colors.white)
        print("Enter video URL:")
        print("(meta.json or manifest.json)")
        print()
        term.setTextColor(colors.gray)
        print("Controls:")
        print("  Space = Pause/Resume")
        print("  Q = Quit")
        print()
        term.setTextColor(colors.white)
        term.write("URL: ")
        url = read()
    end
    
    if not url or url == "" then
        return
    end
    
    term.clear()
    term.setCursorPos(1, 1)
    print("Loading...")
    
    local ok, err = pcall(play, url)
    
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    
    if ok then
        print("Playback finished!")
    else
        term.setTextColor(colors.red)
        print("Error: " .. tostring(err))
    end
    
    print()
    print("Press any key...")
    os.pullEvent("key")
    
    main({})
end

main({...})