--============================================================
-- 文件：screens/redux/itemservercontactpopup.lua
-- 模块：redux / itemservercontactpopup
-- 职责：redux模块中的「itemservercontactpopup」。具体职责请结合函数实现阅读——本文件属于该模块的组成部分。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local GenericWaitingPopup = require "screens/redux/genericwaitingpopup"

local ItemServerContactPopup = Class(GenericWaitingPopup, function(self)
    GenericWaitingPopup._ctor(self, "ItemServerContactPopup", STRINGS.UI.ITEM_SERVER.CONNECT, nil, true)

    --text
    self.text = self.dialog.body
end)

--[[
function LaunchingServerPopup:OnUpdate( dt )
    local status = TheNet:GetChildProcessStatus()
	local hasError = TheNet:GetChildProcessError() or self.errorStartingServers
    -- 0 : not starting, not existing
    -- 1 : process is starting
    -- 2 : worldgen
    -- 3 : ready to accept connection
    --print("STATUS IS ", status);

	if hasError then
        if self.worldgenscreen and TheFrontEnd:GetActiveScreen() == self.worldgenscreen then
            TheFrontEnd:PopScreen()
        end

        if TheFrontEnd:GetActiveScreen() == self then
            TheFrontEnd:PopScreen()
        end

		self.errorCallback()

	elseif status == 0 or status == 1 or status == 2 then
        -- SEE QuickJoinScreen for how to add body to popup.
        self.status_msg = status == 2 and STRINGS.UI.NOTIFICATION.SERVER_WORLDGEN or STRINGS.UI.NOTIFICATION.LAUNCHING_SERVER
    --elseif status == 2 then
        --if self.worldgenscreen == nil then
            --self.worldgenscreen = TheFrontEnd:PushScreen(WorldGenScreen())
        --end
    elseif status == 3 then
        --if self.worldgenscreen and TheFrontEnd:GetActiveScreen() == self.worldgenscreen then
            --TheFrontEnd:PopScreen()
        --end
        if TheFrontEnd:GetActiveScreen() == self then
            TheFrontEnd:PopScreen()
        end
        self.successCallback(self.serverinfo)
    end
end]]

function ItemServerContactPopup:Close()
    self:OnCancel()
end

return ItemServerContactPopup
