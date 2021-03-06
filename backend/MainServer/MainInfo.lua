------------------------------------------------------
---! @file
---! @brief MainInfo, 保存所有连接节点信息
------------------------------------------------------

---! 依赖库
local skynet    = require "skynet"
local cluster   = require "skynet.cluster"

---! 帮助库
local clsHelper    = require "ClusterHelper"
local filterHelper = require "FilterHelper"
local strHelper = require "StringHelper"

---! 全局常量
local nodeInfo = nil
local appName = nil

local info = {}
local main = {}

---! detect master MainServer
local function do_detectMaster (app, addr)
    if app < appName then
        if main[app] then
            return
        end
        main[app] = addr
        skynet.error("hold the main server", app)
        pcall(cluster.call, app, addr, "LINK", true)
        skynet.error("disconnect the main server", app)
        main[app] = nil
    else
        addr = clsHelper.cluster_addr(app, clsHelper.kMainInfo)
        if addr then
            pcall(cluster.call, app, addr, "holdMain", appName)
        end
    end
end

---! loop in the back to detect master
local function detectMaster ()
    local list = skynet.call(nodeInfo, "lua", "getConfig", clsHelper.kMainServer)
    table.sort(list, function (a, b)
        return a < b
    end)

    for _, app in ipairs(list) do
        if app ~= appName then
            local addr = clsHelper.cluster_addr(app, clsHelper.kNodeLink)
            if addr then
                skynet.fork(function ()
                    do_detectMaster(app, addr)
                end)
            end
        end
    end
end

---! other node comes to register, check if any master
local function checkBreak ()
    for app, _ in pairs(main) do
        if app < appName then
            skynet.error(appName, "find better to break", app)
            skynet.call(nodeInfo, "lua", "nodeOff")
            skynet.sleep(3 * 100)
            skynet.newservice("NodeLink")
            break
        end
    end
end

---! 对方节点断线
local function disconnect_kind_server (kind, name)
    local list = info[kind] or {}
    list.name = nil
end

---! 维持与别的节点的联系
local function hold_kind_server (kind, name)
    local addr = clsHelper.cluster_addr(name, clsHelper.kNodeLink)
    if not addr then
        disconnect_kind_server(kind, name)
        return
    end

    skynet.error("hold kind server", kind, name)
    pcall(cluster.call, name, addr, "LINK", true)
    skynet.error("disconnect kind server", kind, name)

    disconnect_kind_server(kind, name)
end


---! lua commands
local CMD = {}

---! hold other master
function CMD.holdMain (otherName)
    if otherName >= appName or main[otherName] then
        return 0
    end

    local addr = clsHelper.cluster_addr(otherName, clsHelper.kNodeLink)
    if not addr then
        return 0
    end

    main[otherName] = addr

    skynet.fork(function ()
        skynet.error("hold the main server", otherName)
        pcall(cluster.call, otherName, addr, "LINK", true)
        skynet.error("disconnect the main server", otherName)
        main[otherName] = nil
    end)

    skynet.fork(checkBreak)

    return 0
end

---! ask all possible nodes to register them
function CMD.askAll ()
    info = {}

    local all = skynet.call(nodeInfo, "lua", "getConfig", clsHelper.kAgentServer)
    local list = skynet.call(nodeInfo, "lua", "getConfig", clsHelper.kHallServer)
    for _, v in ipairs(list) do
        table.insert(all, v)
    end

    for _, app in ipairs(all) do
        local addr = clsHelper.cluster_addr(app, clsHelper.kNodeLink)
        if addr then
            pcall(cluster.call, app, addr, "askReg")
        end
    end
end

---! node info to register
function CMD.regNode (node)
    local kind = node.kind
    assert(filterHelper.isElementInArray(kind, {clsHelper.kAgentServer, clsHelper.kHallServer}))

    local list = info[kind] or {}
    info[kind] = list

    local one = {}
    one.clusterName   = node.name
    one.address       = node.addr
    one.port          = node.port
    one.numPlayers    = node.numPlayers
    one.lastUpdate    = os.time()

    skynet.error(kind, "regNode", node.name)

    local config = node.conf
    if config then
        one.gameId         = tonumber(config.GameId) or 0
        one.gameMode       = tonumber(config.GameMode) or 0
        one.gameVersion    = tonumber(config.Version) or 0
        one.lowVersion     = tonumber(config.LowestVersion) or 0
        one.hallName       = config.HallName
        one.lowPlayers     = config.Low
        one.highPlayers    = config.High
    end

    list[node.name] = one

    skynet.fork(function()
        hold_kind_server(kind, node.name)
    end)

    skynet.fork(checkBreak)

    return 0
end

---! get the server stat
function CMD.getStat ()
    local agentNum, hallNum = 0,0

    local str = nil
    local arr = {}
    table.insert(arr, os.date() .. "\n")
    table.insert(arr, "[Agent List]\n")

    local agentCount = 0
    local list = info[clsHelper.kAgentServer] or {}
    for _, one in pairs(list) do
        agentCount = agentCount + one.numPlayers
        agentNum = agentNum + 1
        str = string.format("%s\t%s:%d num:%d\n", one.clusterName, one.address, one.port, one.numPlayers)
        table.insert(arr, str)
    end

    local hallCount = 0
    table.insert(arr, "\n[Hall List]\n")
    list = info[clsHelper.kHallServer] or {}
    table.sort(list, function(a, b)
        return a.clusterName < b.clusterName
    end)
    for _, one in pairs(list) do
        hallCount = hallCount + one.numPlayers
        hallNum = hallNum + 1
        str = string.format("%s\t%s:%d num:%d \t=> [%d, %d]", one.clusterName, one.address, one.port, one.numPlayers, one.lowPlayers, one.highPlayers)
        table.insert(arr, str)
        str = string.format("\t%s id:%s mode:%s version:%s low:%s\n", one.hallName, one.gameId, one.gameMode, one.gameVersion, one.lowVersion or "0")
        table.insert(arr, str)
    end

    str = string.format("\n大厅服务器数目:%d \t客户服务器数目:%d \t登陆人数:%d \t游戏人数:%d\n",
                            hallNum, agentNum, hallCount, agentCount)
    table.insert(arr, str)

    return strHelper.join(arr, "")
end

---! 服务的启动函数
skynet.start(function()
    ---! 初始化随机数
    math.randomseed( tonumber(tostring(os.time()):reverse():sub(1,6)) )

    ---! 注册skynet消息服务
    skynet.dispatch("lua", function(_,_, cmd, ...)
        local f = CMD[cmd]
        if f then
            local ret = f(...)
            if ret then
                skynet.ret(skynet.pack(ret))
            end
        else
            skynet.error("unknown command ", cmd)
        end
    end)

    ---! 获得NodeInfo 服务
    nodeInfo = skynet.uniqueservice(clsHelper.kNodeInfo)
    skynet.call(nodeInfo, "lua", "updateConfig", skynet.self(), clsHelper.kMainInfo)

    appName = skynet.call(nodeInfo, "lua", "getConfig", "nodeInfo", "appName")

    ---! ask all nodes to register
    skynet.fork(CMD.askAll)

    ---! run in the back, detect master
    skynet.fork(detectMaster)
end)

