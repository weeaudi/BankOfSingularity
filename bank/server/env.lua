local M = {}

local okComponent, component = pcall(require, 'component')
local okComputer = pcall(require, 'computer')

M.isOc = okComponent and type(component) == 'table' and okComputer

function M.now()
    if M.isOc then
        ---@diagnostic disable-next-line: undefined-field
        return require('computer').uptime()
    else
        return os.clock()
    end
end

print(('OC Env: %s'):format(M.isOc))

return M
