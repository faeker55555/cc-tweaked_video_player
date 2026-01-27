-- CC:Tweaked Video Player v5.0
-- Monitor support + per-frame palettes

local VERSION = "5.0"

-- ============================================
-- Monitor Detection
-- ============================================

local function findMonitors()
    local monitors = {}
    
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "monitor" then
            local mon = peripheral.wrap(name)
            local w, h = mon.getSize()
            table.insert(monitors, {
                name = name,
                monitor = mon,
                width = w,
                height = h,
                pixels_w = w * 2,  -- Pixelbox doubles width
                pixels_h = h * 3   -- Pixelbox triples height
            })
        end
    end
    
    -- Sort by size (largest first)
    table.sort(monitors, function(a, b)
        return (a.width * a.height) > (b.width * b.height)
    end)
    
    return monitors
end

local function selectDisplay()
    local monitors = findMonitors()
    
    print("Available displays:")
    print("  [0] Terminal (" .. term.getSize() .. " chars)")
    
    for i, mon in ipairs(monitors) do
        print(string.format("  [%d] %s (%dx%d chars, %dx%d pixels)",
            i, mon.name, mon.width, mon.height, mon.pixels_w, mon.pixels_h))
    end
    
    print()
    print("Select display (0-" .. #monitors .. "): ")
    
    local choice = tonumber(read()) or 0
    
    if choice == 0 then
        return term.current(), nil
    elseif choice > 0 and choice <= #monitors then
        return monitors[choice].monitor, monitors[choice]
    else
        return term.current(), nil
    end
end

-- ============================================
-- Auto-install Pixelbox
-- ============================================

if not fs.exists("pixelbox_lite.lua") then
    print("Installing Pixelbox Lite...")
    shell.run("wget", "https://raw.githubusercontent.com/9551-Dev/pixelbox_lite/master/pixelbox_lite.lua")
end

-- ============================================
-- Utilities
-- ============================================

local function readU32(data, pos)
    return data:byte(pos) + data:byte(pos+1)*256 + 
           data:byte(pos+2)*65536 + data:byte(pos+3)*16777216
end

local function readU16(data, pos)
    return data:byte(pos) + data:byte(pos+1)*256
end

local function httpGet(url, binary)
    local r = http.get(url, nil, binary)
    if r then
        local d = r.readAll()
        r.close()
        return d
    end
    return nil
end

local function httpGetJSON(url)
    local d = httpGet(url, false)
    return d and textutils.unserializeJSON(d)
end

-- ============================================
-- RLE Decompressor
-- ============================================

local function decompressRLE(data)
    local result = {}
    local i = 1
    
    while i <= #data do
        local h = data:byte(i)
        i = i + 1
        
        if bit32.band(h, 0x80) ~= 0 then
            local count = bit32.band(h, 0x7F) + 1
            local val = data:byte(i)
            i = i + 1
            for j = 1, count do
                result[#result + 1] = val
            end
        else
            local count = bit32.band(h, 0x7F) + 1
            for j = 1, count do
                result[#result + 1] = data:byte(i)
                i = i + 1
            end
        end
    end
    
    return result
end

-- ============================================
-- Frame Decoder (per-frame palette support)
-- ============================================

local decoder = {
    palette = {},
    prevFrame = nil,
    width = 0,
    height = 0,
}

function decoder:init(w, h)
    self.width = w
    self.height = h
    self.prevFrame = nil
    self.palette = {}
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
    
    -- Read palette if present
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
    
    local frame
    if isDelta and self.prevFrame then
        frame = {}
        for i = 1, #pixels do
            if bit32.band(pixels[i], 0x10) ~= 0 then
                frame[i] = bit32.band(pixels[i], 0x0F)
            else
                frame[i] = self.prevFrame[i] or 0
            end
        end
    else
        frame = {}
        for i = 1, #pixels do
            frame[i] = bit32.band(pixels[i], 0x0F)
        end
    end
    
    self.prevFrame = frame
    return frame, self.palette
end

function decoder:applyPalette(display)
    for i = 1, 16 do
        local c = self.palette[i]
        display.setPaletteColor(2^(i-1), c[1]/255, c[2]/255, c[3]/255)
    end
end

-- ============================================
-- Audio Player
-- ============================================

local speaker = peripheral.find("speaker")
local dfpwm = nil
pcall(function() dfpwm = require("cc.audio.dfpwm") end)

local audioDecoder = dfpwm and dfpwm.make_decoder() or nil

local function playAudio(data)
    if not speaker or not data or #data == 0 then
        return
    end
    
    if audioDecoder then
        local samples = audioDecoder(data)
        if samples then
            speaker.playAudio(samples)
        end
    end
end

-- ============================================
-- Segment Loader
-- ============================================

local segmentCache = {}

local function loadSegment(url, index)
    if segmentCache[index] then
        return segmentCache[index]
    end
    
    local data = httpGet(url, true)
    if not data then return nil end
    
    -- Check magic (CCV1 or CCV2)
    local magic = data:sub(1, 4)
    if magic ~= "CCV1" and magic ~= "CCV2" then
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
        
        local audioData = nil
        if audioSize > 0 then
            audioData = data:sub(pos, pos + audioSize - 1)
            pos = pos + audioSize
        end
        
        frames[i] = { video = frameData, audio = audioData }
    end
    
    segmentCache[index] = { frames = frames }
    
    -- Limit cache
    local count = 0
    for _ in pairs(segmentCache) do count = count + 1 end
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

-- ============================================
-- Player
-- ============================================

local function play(url, display, monitorInfo)
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
        return
    end
    
    -- Setup pixelbox
    local box = require("pixelbox_lite").new(display)
    
    -- Show info
    display.setBackgroundColor(colors.black)
    display.setTextColor(colors.white)
    display.clear()
    display.setCursorPos(1, 1)
    
    print(string.format("Video: %dx%d @ %.1f fps", meta.width, meta.height, meta.fps))
    print(string.format("Duration: %.1f min (%d frames)", meta.duration/60, meta.total_frames))
    print(string.format("Segments: %d", #meta.segments))
    print(string.format("Audio: %s", meta.has_audio and "Yes" or "No"))
    
    if monitorInfo then
        print(string.format("Display: %s (%dx%d)", monitorInfo.name, 
              monitorInfo.pixels_w, monitorInfo.pixels_h))
    else
        print("Display: Terminal")
    end
    
    if speaker then
        print("Speaker: Found")
    else
        print("Speaker: Not found")
    end
    
    print()
    print("Press any key to start...")
    print("(Space=Pause, Q=Quit)")
    os.pullEvent("key")
    
    -- Init decoder
    decoder:init(meta.width, meta.height)
    segmentCache = {}
    
    -- Playback state
    local playing = true
    local paused = false
    local segmentIndex = 0
    local frameIndex = 1
    local globalFrame = 0
    
    local frameTime = 1 / meta.fps
    
    -- Load first segment
    local function getSegmentUrl(idx)
        local seg = meta.segments[idx + 1]
        return seg and seg.url or string.format("%s/seg_%04d.ccv", baseUrl, idx)
    end
    
    local segment = loadSegment(getSegmentUrl(0), 0)
    if not segment then
        print("Failed to load first segment!")
        return
    end
    
    -- Pre-buffer
    if #meta.segments > 1 then
        loadSegment(getSegmentUrl(1), 1)
    end
    
    -- Timing
    local lastTime = os.clock()
    local accumulator = 0
    
    while playing do
        local now = os.clock()
        local dt = now - lastTime
        lastTime = now
        
        if not paused then
            accumulator = accumulator + dt
            
            while accumulator >= frameTime and playing do
                accumulator = accumulator - frameTime
                
                -- Next segment?
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
                    
                    -- Pre-buffer next
                    local nextIdx = segmentIndex + 1
                    if nextIdx < #meta.segments and not segmentCache[nextIdx] then
                        loadSegment(getSegmentUrl(nextIdx), nextIdx)
                    end
                end
                
                -- Process frame
                local frameData = segment.frames[frameIndex]
                if frameData then
                    -- Decode
                    local pixels, palette = decoder:decode(frameData.video)
                    
                    -- Apply palette
                    decoder:applyPalette(display)
                    
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
                    
                    -- Status
                    local sw, sh = display.getSize()
                    display.setCursorPos(1, sh)
                    display.setBackgroundColor(colors.gray)
                    display.clearLine()
                    
                    local progress = globalFrame / meta.total_frames
                    local t = globalFrame / meta.fps
                    
                    display.write(string.format(" %s %d:%02d/%d:%02d [%d%%]",
                        paused and "||" or "\16",
                        math.floor(t/60), math.floor(t%60),
                        math.floor(meta.duration/60), math.floor(meta.duration%60),
                        math.floor(progress * 100)))
                    
                    display.setBackgroundColor(colors.black)
                end
                
                frameIndex = frameIndex + 1
                globalFrame = globalFrame + 1
                
                if globalFrame >= meta.total_frames then
                    playing = false
                    break
                end
            end
        else
            -- Paused display
            local sw, sh = display.getSize()
            display.setCursorPos(1, sh)
            display.setBackgroundColor(colors.gray)
            display.clearLine()
            display.write(" || PAUSED - Space to resume")
            display.setBackgroundColor(colors.black)
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
                -- Ready for more audio
            end
        end
    end
    
    -- Reset palette
    for i = 0, 15 do
        display.setPaletteColor(2^i, term.nativePaletteColor(2^i))
    end
    
    return true
end

-- ============================================
-- Main
-- ============================================

local function main(args)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    
    print("=== CC Video Player v" .. VERSION .. " ===")
    print()
    
    -- Select display
    local display, monitorInfo = selectDisplay()
    
    -- Get URL
    local url = args[1]
    
    if not url then
        print()
        print("Enter video URL (meta.json):")
        url = read()
    end
    
    if not url or url == "" then
        return
    end
    
    -- Play
    display.clear()
    display.setCursorPos(1, 1)
    print("Loading...")
    
    local ok, err = pcall(play, url, display, monitorInfo)
    
    -- Cleanup
    display.setBackgroundColor(colors.black)
    display.setTextColor(colors.white)
    display.clear()
    display.setCursorPos(1, 1)
    
    if ok then
        print("Playback finished!")
    else
        print("Error: " .. tostring(err))
    end
    
    print()
    print("Press any key...")
    os.pullEvent("key")
    
    main({})
end

main({...})