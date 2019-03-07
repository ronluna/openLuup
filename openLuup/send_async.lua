local posix = require "posix"
local closefds = require "openLuup.closefds"

local function close_all_sockets_except_client (sock)

  assert(sock)

  --[[ DEBUG
  local fail = false
  if not sock.getsockname
  or not sock.getpeername
  then
    print("sock:", sock)
    print("type(sock):", type(sock))
    print("sock.getpeername:", sock.getpeername)
    print("sock.getsockname:", sock.getsockname)
    for k, v in pairs(sock) do
      print("sock kv:", k, v)
    end
    fail = true
  end

  if fail then
    error("crash close socks")
  end
  ]]

  local l_ip, l_port = sock:getsockname()
  local p_ip, p_port = sock:getpeername()
  if not l_ip
  or not l_port
  or not p_ip
  or not p_port
  then
    return nil, "not enough data to select client socket"
  end

  local sock_info = {
    local_ip   = l_ip,
    local_port = l_port,
    peer_ip    = p_ip,
    peer_port  = p_port,
    type = "stream",
    sock = sock,
  }

  local sock_fd, descr = closefds.get_sock_fd_by_addr(sock_info)
  if not sock_fd then
    return nil, "cannot get client socket fd: "..tostring(descr)
  end

  local ok, descr = closefds.close_all_sockets_except {sock_fd}
  if not ok then
    return nil, "cannot close other fds except client sock fd: "..tostring(descr)
  end

  return true
end

local response_no = 0
local function send_async_simple (sock, data)

  response_no = response_no + 1

  local pid = posix.fork()
  if pid == 0 then

    -- THREAD BEGIN --------
    local pcall_ok, pcall_descr = pcall(function()


    -- close other fds
    local close_ok, descr = close_all_sockets_except_client(sock)
    if not close_ok then
      print("warning: cannot close all sockets except "..tostring(sock)
          ..": "..tostring(descr))
    end

    if not close_ok then
      print(os.date(), string.format("start sending %d bytes of data...", #data))
    end

    local ok, descr, stop
    local pos = 1
    repeat
      ok, descr, stop = sock:send(data, pos)
      if not ok
      and (descr == "timeout" or descr == "wantwrite")
      then
        pos = stop + 1
      end
    until ok
        or (
          not ok
          and descr ~= "timeout"
          and descr ~= "wantwrite"
        )

    if not close_ok then
      print(os.date(), string.format("sock:send returned %s, %s, %s",
          tostring(ok), tostring(descr), tostring(part)))
    end

    end)

    if not pcall_ok then
      print("send_async_simple(): Lua error: "..tostring(pcall_descr))
    end

    os.exit()
    -- THREAD END --------
  end
end

-- specific encoding for chunked messages (trying to avoid long string problem)
local function gen_chunked_response (data, nchunks)
  local datalen = #data
  chunksize = nchunks or datalen

  -- Generate chunked data
  local chunked_t = {}
  for i = 1, datalen, chunksize do
    local part = string.sub(data, i, i + chunksize - 1)
    if part and #part > 0 then
      table.insert(chunked_t, string.format("%x\r\n", #part))
      table.insert(chunked_t, part)
      table.insert(chunked_t, "\r\n")
    end
  end
  table.insert(chunked_t, "0\r\n\r\n")
  local chunked_s = table.concat(chunked_t, "")

  return chunked_s
end

return {
  close_all_sockets_except_client = close_all_sockets_except_client,
  send_async_simple = send_async_simple,
  gen_chunked_response = gen_chunked_response,
}

