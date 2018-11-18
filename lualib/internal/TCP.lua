local class = require "class"
local ti = require "internal.Timer"

local tcp = core_tcp
local co_new = coroutine.create
local co_start = coroutine.resume
local co_wakeup = coroutine.resume
local co_suspend = coroutine.yield
local co_self = coroutine.running

local EVENT_READ  = 0x01
local EVENT_WRITE = 0x02

local SERVER = 0
local CLIENT = 1

local TCP = class("Socket")

function TCP:ctor(opt)
    self.co = nil           -- 当前协程(相对来说)
    self.fd = nil           -- 套接字文件描述符
    self.type = nil         -- client or server
    self.tcp = nil       -- 套接字对象
    self.accept_co = nil    -- accept 协程
    self.connect_co = nil   -- connect 协程
    self.status = "inited"
end

function TCP:set_status(status)
    self.status = status
end

-- 设置回调函数
function TCP:set_cb(action, cb)
    if not self[action] and action and type(cb) == "function" then
        self[action] = cb  -- 运行时不能替换回调
    end
end

-- 超时时间
function TCP:timeout(Interval)
    if Interval and Interval > 0 then
        self._timeout = Interval
    end
end

-- 设置fd
function TCP:set_fd(fd)
    if not self.fd then
        self.fd = fd
    end
end

function TCP:send(data)
    if self.status ~= "connected" then
        return
    end
    if not self.tcp and not self.fd then
        return
    end
    self.co = co_self()
    self.write_co = co_new(function (...)
        local send_data = data
        local send_len
        while 1 do
            send_len = self.tcp:write(send_data)
            if not send_len or #send_data == send_len then
                local co = self.co
                self.co = nil
                self.tcp:stop()
                self.write_co = nil
                local ok, err = co_wakeup(co, send_len)
                if not ok then
                    print(err)
                    self.tcp:close()
                end
                return
            end
            if #send_data > send_len then
                send_data = string.sub(send_data, send_len + 1, -1)
            end
            co_suspend()
        end
    end)
    self.tcp:start(self.fd, EVENT_WRITE, self.write_co)
    return co_suspend()
end

function TCP:recvall()
    if self.status ~= "connected" then
        return
    end
    if not self.tcp and not self.fd then
        return
    end
    local read = true
    local timeout = true
    self.co = co_self()
    self.read_co = co_new(function ( ... )
        if read then
            local buf, len = self.tcp:readall()
            local co = self.co
            timeout = nil
            self.read_ti = nil
            self.co = nil
            self.read_co = nil
            self.tcp:stop()
            if not buf then
                self.status = "closed"
                local ok, err = co_wakeup(co, buf, len)
                if not ok then
                    print(err)
                end
                return
            end
            local ok, err = co_wakeup(co, buf, len)
            if not ok then
                print(err)
            end
            return
        end
    end)
    self.read_ti = ti.timeout(self._timeout, co_new(function ( ... )
        if timeout then
            local co = self.co
            self.co = nil
            self.read_co = nil
            read = nil
            self.tcp:stop()
            local ok, err = co_wakeup(co, nil, "read timeout")
            if not ok then
                print(err)
            end
            self.read_ti = nil
        end
    end))
    self.tcp:start(self.fd, EVENT_READ, self.read_co)
    return co_suspend()
end

function TCP:recv(bytes)
    if self.status ~= "connected" then
        return
    end
    if not self.tcp and not self.fd then
        return
    end
    local read = true
    local timeout = true
    self.co = co_self()
    self.read_co = co_new(function ( ... )
        if read then
            local buf, len = self.tcp:read(bytes)
            local co = self.co
            self.co = nil
            self.read_co = nil
            self.timeout = nil
            self.tcp:stop()
            if not buf then
                self:set_status("closed")
                local ok, err = co_wakeup(co)
                if not ok then
                    print(err)
                end
                return
            end
            local ok, err = co_wakeup(co, buf, len)
            if not ok then
                print(err)
            end
        end
    end)
    self.read_ti = ti.timeout(self._timeout, function ( ... )
        if timeout then
            local co = self.co
            read = nil
            self.co = nil
            self.read_co = nil
            self.tcp:stop()
            local ok, err = co_wakeup(co, nil, "read timeout")
            if not ok then
                print(err)
            end
            self.read_ti = nil
            return
        end
    end)
    self.tcp:start(self.fd, EVENT_READ, self.read_co)
    return co_suspend()
end

function TCP:listen(ip, port)
    if self.type == CLIENT then
        print("this socket object already used in client mode! :) ")
        return
    end
    self.type = SERVER
    self.tcp = self.tcp or tcp:new()
    if not self.tcp then
        print("Listen Socket Create Error! :) ")
        return
    end
    self.fd = self.fd or self.tcp:new_tcp_fd(ip, port, SERVER)
    if not self.fd then
        print("this IP and port Create A bind or listen method Faild! :) ")
        self.tcp = nil
        return
    end
    self.accept_co = co_new(function (fd, ipaddr)
        while 1 do
            print(fd, ipaddr)
            if fd and ipaddr then
                if self.accept and type(self.accept) == "function" then
                    local ok, msg = co_start(co_new(self.accept, fd, ipaddr))
                    if not ok then
                        print("Accept function error:", msg)
                    end
                else
                    print("Please Set Socket Accept Callback Method! :) ")
                    self.fd = nil
                    self.accept_co = nil
                    self.tcp:close()
                end
            end
            fd, ipaddr = co_suspend()
        end
    end)
    return self.tcp:listen(self.fd, self.accept_co)
end

function TCP:connect(domain, port)
    if self.type == SERVER then
        print("this socket object already used in server mode! :) ")
        return
    end
    self.tcp = self.tcp or tcp:new()
    if not self.tcp then
        print("Create a Connect Socket Error! :) ")
        return
    end
    self.fd = self.tcp:new_tcp_fd(domain, port, CLIENT)
    if not self.fd then
        print("Connect This IP or Port Faild! :) ")
        self.tcp = nil
        return
    end
    self.type = CLIENT
    self.co = co_self()
    local timeout = true
    local connect = true
    self.connect_co = co_new(function (connected)
        if connect then
            self.tcp:stop()
            self.connect_co = nil
            timeout = nil
            local co = self.co
            if connected then
                self:set_status("connected")
                local ok, msg = co_wakeup(co, true)
                if not ok then
                    print(msg)
                end
                return
            end
            local ok, msg = co_wakeup(co)
            if not ok then
                print(msg)
            end
            return
        end
    end)
    self.connect_ti = ti.timeout(self._timeout, function ( ... )
        if timeout then
            self.tcp:stop()
            self.connect_co = nil
            connect = nil
            co_wakeup(self.co, nil, 'connect timeot.')
        end
    end)
    self.tcp:connect(self.fd, self.connect_co)
    return co_suspend()
end

-- clear 用于清理后再使用
function TCP:clear(...)
    self.co = nil
    self.fd = nil
    self.type = nil
    self.accept_co = nil
    self.connect_co = nil
    self.read_co = nil
    self.write_co = nil
end

-- clear 用于关闭
function TCP:close(...)
    if self.tcp then
        self.tcp:close()
        self.tcp = nil
    end
    self.co = nil
    self.fd = nil
    self.type = nil
    self.accept_co = nil
    self.connect_co = nil
    self.read_co = nil
    self.write_co = nil
end

return TCP