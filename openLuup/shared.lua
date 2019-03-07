local p = {}

p.sock_to_sslsock = {}
p.sslsock_to_sock = {}

p.sock_peer_ip = {}
p.sock_peer_port = {}
p.sock_local_ip = {}
p.sock_local_port = {}

setmetatable(p.sock_to_sslsock, { __mode = "k"})
setmetatable(p.sslsock_to_sock, { __mode = "k"})

setmetatable(p.sock_peer_ip,    { __mode = "k"})
setmetatable(p.sock_peer_port,  { __mode = "k"})
setmetatable(p.sock_local_ip,   { __mode = "k"})
setmetatable(p.sock_local_port, { __mode = "k"})

p.TaskMessageQueue = {}
p.event = {
	dev_io_read_error_callbacks = {}, -- args @dev_t, @dev_no, @err_descr
	dev_io_open_callbacks = {}, -- args @dev_t, @dev_no
	dev_io_open_error_callbacks = {}, -- args @dev_t, @dev_no, @err_descr
}

p.current_server_sock = nil
p.current_client_sock = nil

-- scene status needs this
p.known_action_schemes = {}
p.known_action_schemes_all = {}

function p.ssltonormalsock(sock)
	if sock and p.sslsock_to_sock[sock] then
		return p.sslsock_to_sock[sock]
	else
		return sock
	end
end

function p.get_current_server_sock()
	return p.current_server_sock
end

function p.get_current_client_sock()
	return p.current_client_sock
end

local p1 = {}

setmetatable(p1, {
	__index = function(t, key)
		return p[key]
	end,
	__newindex = function(t, key, val)
		p[key] = val
		return true
	end,
})

return p1

