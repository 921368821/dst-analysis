--============================================================
-- 文件：datagrid.lua
-- 模块： / datagrid
-- 职责：模块中的「datagrid」。具体职责请结合函数实现阅读——本文件属于该模块的组成部分。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

DataGrid = Class(function(self, width, height)
	self.grid = {}
	self.width = width
	self.height = height
end)

function DataGrid:Width()
	return self.width
end

function DataGrid:Height()
	return self.height
end

function DataGrid:GetMaxSize()
	return self.width * self.height
end

function DataGrid:GetIndex(x, y)
	return y * self.width + x
end

function DataGrid:GetXYFromIndex(index)
	return index % self.width, math.floor(index / self.width)
end

function DataGrid:GetDataAtPoint(x, y)
	return self:GetDataAtIndex(self:GetIndex(x, y))
end

function DataGrid:SetDataAtPoint(x, y, data)
	return self:SetDataAtIndex(self:GetIndex(x, y), data)
end

function DataGrid:GetDataAtIndex(index)
	return self.grid[index]
end

function DataGrid:SetDataAtIndex(index, data)
	self.grid[index] = data
end

function DataGrid:Save()
	return self.grid
end

function DataGrid:Load(grid)
	self.grid = grid
end