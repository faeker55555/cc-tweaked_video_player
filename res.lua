local function drawTest(display, name)
    -- Try to set scale 0.5 if it's a monitor
    local isMonitor = false
    if display.setTextScale then
        display.setTextScale(0.5)
        isMonitor = true
    end

    local w, h = display.getSize()
    local pxW, pxH = w * 2, h * 3

    display.setBackgroundColor(colors.black)
    display.clear()
    
    display.setCursorPos(1, math.floor(h/2) - 2)
    display.setTextColor(colors.yellow)
    local title = "--- HD DISPLAY TEST ---"
    display.setCursorPos(math.floor(w/2 - #title/2)+1, math.floor(h/2)-2)
    display.write(title)

    display.setTextColor(colors.white)
    local info = string.format("Resolution: %dx%d pixels", pxW, pxH)
    display.setCursorPos(math.floor(w/2 - #info/2)+1, math.floor(h/2))
    display.write(info)

    display.setTextColor(colors.lime)
    local cmd = string.format("Encoder: -w %d -H %d", pxW, pxH)
    display.setCursorPos(math.floor(w/2 - #cmd/2)+1, math.floor(h/2)+2)
    display.write(cmd)

    os.pullEvent("key")
    if isMonitor then display.setTextScale(1) end
end

local monitors = { "terminal" }
for _, n in ipairs(peripheral.getNames()) do
    if peripheral.getType(n) == "monitor" then table.insert(monitors, n) end
end

print("Select display:")
for i, n in ipairs(monitors) do print(i .. ": " .. n) end
local choice = tonumber(read())
if choice and monitors[choice] then
    local d = monitors[choice] == "terminal" and term or peripheral.wrap(monitors[choice])
    drawTest(d, monitors[choice])
end