local fw    = require 'bee.filewatch'
local fs    = require 'bee.filesystem'
local plat  = require 'bee.platform'
local await = require 'await'

local MODIFY = 1 << 0
local RENAME = 1 << 1

local function isExists(filename)
    local path = fs.path(filename)
    local suc, exists = pcall(fs.exists, path)
    if not suc or not exists then
        return false
    end
    if plat.OS ~= 'Windows' then
        return true
    end
    local suc, res = pcall(fs.fullpath, path)
    if not suc then
        return false
    end
    if res :string():gsub('^%w+:', string.lower)
    ~= path:string():gsub('^%w+:', string.lower) then
        return false
    end
    return true
end

---@class filewatch
local m = {}

m._eventList = {}
m._watchings = {}

---@param path string
---@param recursive boolean
---@param filter? fun(path: string):boolean
function m.watch(path, recursive, filter)
    if path == '' or not fs.is_directory(fs.path(path)) then
        return function () end
    end
    if m._watchings[path] then
        m._watchings[path].count = m._watchings[path].count + 1
    else
        local watch = fw.create()
        watch:add(path)
        log.debug('Watch add:', path)
        if recursive then
            local function scanDirctory(dir)
                for fullpath in fs.pairs(dir) do
                    if fs.is_directory(fullpath) then
                        if not filter or filter(fullpath:string()) then
                            watch:add(fullpath:string())
                            log.debug('Watch add:', fullpath:string())
                            scanDirctory(fullpath)
                        end
                    end
                end
            end

            scanDirctory(fs.path(path))
        end
        m._watchings[path] = {
            count = 1,
            watch = watch,
        }
        log.debug('fw.add', path)
    end
    local removed
    return function ()
        if removed then
            return
        end
        removed = true
        m._watchings[path].count = m._watchings[path].count - 1
        if m._watchings[path].count == 0 then
            m._watchings[path] = nil
            log.debug('fw.remove', path)
        end
    end
end

---@param callback async fun(ev: string, path: string)
function m.event(callback)
    m._eventList[#m._eventList+1] = callback
end

function m._callEvent(ev, path)
    for _, callback in ipairs(m._eventList) do
        await.call(function ()
            callback(ev, path)
        end)
    end
end

function m.update()
    local collect
    for _, watching in pairs(m._watchings) do
        local watch = watching.watch
        for _ = 1, 10000 do
            local ev, path = watch:select()
            if not ev then
                break
            end
            log.debug('filewatch:', ev, path)
            if not collect then
                collect = {}
            end
            if ev == 'modify' then
                collect[path] = (collect[path] or 0) | MODIFY
            elseif ev == 'rename' then
                collect[path] = (collect[path] or 0) | RENAME
            end
        end
    end

    if not collect or not next(collect) then
        return
    end

    for path, flag in pairs(collect) do
        if flag & RENAME ~= 0 then
            if isExists(path) then
                m._callEvent('create', path)
            else
                m._callEvent('delete', path)
            end
        elseif flag & MODIFY ~= 0 then
            m._callEvent('change', path)
        end
    end

end

return m
