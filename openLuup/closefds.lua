local m = {}

local fdctl = require "fdctl"
require "lfs"

function m.get_sock_fd_by_addr (info)
	for fd_no in lfs.dir("/proc/self/fd") do
		fd_no = tonumber(fd_no)
		if fd_no
		and fd_no ~= 0
		and fd_no ~= 1
		and fd_no ~= 2
		then
			local fullfname = "/proc/self/fd/"..tostring(fd_no)
			local ftype = fdctl.gettype(fullfname)
			if ftype == "socket" then
				local fd_info = {}
				fd_info.local_ip, fd_info.local_port = fdctl.getsockname(fd_no)
				fd_info.peer_ip, fd_info.peer_port = fdctl.getpeername(fd_no)
				fd_info.type = fdctl.getsocktype(fd_no)
				-- checking
				if fd_info.local_ip
				and fd_info.peer_ip
				and fd_info.type
				and fd_info.local_ip == info.local_ip
				and fd_info.peer_ip == info.peer_ip
				and tonumber(fd_info.local_port) == tonumber(info.local_port)
				and tonumber(fd_info.peer_port) == tonumber(info.peer_port)
				and fd_info.type == info.type
				then
					return fd_no
				end
			end
		end
	end
	return nil, "not found"
end

-- does not close stdin, stdout, sterr (0, 1, 2 fds)
-- usage: m.close_all_fds_except({fd1, fd2, ...})
function m.close_all_sockets_except (except_t)

	local closed_count = 0

	local except_fds_hash = {}
	for i, fd in ipairs(except_t) do
		except_fds_hash[assert(tonumber(fd))] = true
	end

	for fd_no in lfs.dir("/proc/self/fd") do
		fd_no = tonumber(fd_no)

		if fd_no
		and fd_no ~= 0
		and fd_no ~= 1
		and fd_no ~= 2
		then
			local fullfname = "/proc/self/fd/"..tostring(fd_no)
			local ftype = fdctl.gettype(fullfname)
			if ftype == "socket" then
				if except_fds_hash[fd_no] then
					-- skip
				else
					local ok, descr = fdctl.close(fd_no)
					if not ok then
						return nil, "cannot close fd #"..tostring(fd_no)..":"..tostring(descr)
					end
					closed_count = closed_count + 1
				end
			end
		end
	end

	return closed_count
end

function m.exec_shell_cmd (cmd)
	local pd, descr = io.popen(cmd, "r")
	if not pd then
		return nil, "cannot open pipe: "..tostring(descr)
	end
	local data, descr = pd:read("*a")
	if not data then
		return nil, "cannot read from pipe: "..tostring(descr)
	end
	pd:close()
	return data
end

function m.get_first_line (str)
	if not str then
		return nil, "arg #1 is not specified"
	end
	local line = string.match(tostring(str), "^([^\r\n]*)")
	return line
end

function m.escape_bash_arg (str)
	return "'"..string.gsub(str, "'", "\\'").."'"
end

function m.read_link (fname)
	if not fname then
		return nil, "filename is not specified"
	end
	local escaped_s = m.escape_bash_arg(fname)
	local data, descr = m.exec_shell_cmd(string.format("readlink -f '%s'", escaped_s))
	if not data then
		return nil, "cannot execute readlink shell cmd: "..tostring(descr)
	end
	local line, descr = m.get_first_line(data)
	if not line then
		return nil, "cannot get first line of results: "..tostring(descr)
	end
	return line
end

return m

