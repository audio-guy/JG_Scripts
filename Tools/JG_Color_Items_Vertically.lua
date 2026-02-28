-- @description Color items vertically
-- @author JG
-- @version 1.0.0
-- @about Colors all selected items that are vertically aligned to a random color.

function getRandomColor()
    return reaper.ColorToNative(math.random(0,255), math.random(0,255), math.random(0,255))|0x1000000
end

function getSelectedItems()
    local selectedItems = {}
    local numSelectedItems = reaper.CountSelectedMediaItems(0)
    for i = 0, numSelectedItems - 1 do
        table.insert(selectedItems, reaper.GetSelectedMediaItem(0, i))
    end
    return selectedItems
end

function main()
    local selectedItems = getSelectedItems()

    if #selectedItems == 0 then
        reaper.ShowMessageBox("No items selected.", "Error", 0)
        return
    end

    -- Sort items by position
    table.sort(selectedItems, function(a, b)
        local posA = reaper.GetMediaItemInfo_Value(a, "D_POSITION")
        local posB = reaper.GetMediaItemInfo_Value(b, "D_POSITION")
        return posA < posB
    end)

    -- Color items vertically aligned
    for i = 1, #selectedItems do
        local item = selectedItems[i]
        local itemStart = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        local itemEnd = itemStart + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
        local randomColor = getRandomColor()
        
        reaper.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", randomColor)

        -- Color all selected items that overlap vertically
        for j = i + 1, #selectedItems do
            local nextItem = selectedItems[j]
            local nextItemStart = reaper.GetMediaItemInfo_Value(nextItem, "D_POSITION")
            local nextItemEnd = nextItemStart + reaper.GetMediaItemInfo_Value(nextItem, "D_LENGTH")

            if nextItemStart < itemEnd and nextItemEnd > itemStart then
                reaper.SetMediaItemInfo_Value(nextItem, "I_CUSTOMCOLOR", randomColor)
            else
                break
            end
        end
    end

    reaper.UpdateArrange()
end

-- Start the script
reaper.Undo_BeginBlock()
main()
reaper.Undo_EndBlock("Color selected vertically aligned items to a random color", -1)
