local hpack = require "hpack"

local mt = {__index = {}}

local frame_parser = {}

-- DATA frame parser
frame_parser[0x0] = function(stream, flags, payload)
  local end_stream = (flags & 0x1) ~= 0
  local padded = (flags & 0x8) ~= 0
  table.insert(stream.data, payload)
  return payload
end

-- HEADERS frame parser
frame_parser[0x1] = function(stream, flags, payload)
  local end_stream = (flags & 0x1) ~= 0
  local end_headers = (flags & 0x4) ~= 0
  local padded = (flags & 0x8) ~= 0
  local pad_length
  if padded then
    pad_length = string.unpack(">B", headers_payload)
  else
    pad_length = 0
  end
  local headers_payload_len = #payload - pad_length
  if pad_length > 0 then
    payload = payload:sub(1, - pad_length - 1)
  end
  local header_list = hpack.decode(stream.connection.hpack_context, payload)
  table.insert(stream.headers, header_list)
  return header_list
end

-- PRIORITY frame parser
frame_parser[0x2] = function(stream, flags, payload)
end

-- RST_STREAM frame parser
frame_parser[0x3] = function(stream, flags, payload)
end

-- SETTING frame parser
frame_parser[0x4] = function(stream, flags, payload)
  local server_settings = stream.connection.default_settings
  local ack = flags & 0x1 ~= 0
  if ack then
    return
  else
    for i = 1, #payload, 6 do
      id, v = string.unpack(">I2 I4", payload, i)
      server_settings[stream.connection.settings_parameters[id]] = v
      server_settings[id] = v
    end
  end
  return server_settings
end

-- PUSH_PROMISE frame parser
frame_parser[0x5] = function(stream, flags, payload)
end

-- PING frame parser
frame_parser[0x6] = function(stream, flags, payload)
end

-- GOAWAY frame parser
frame_parser[0x7] = function(stream, flags, payload)
end

-- WINDOW_UPDATE frame parser
frame_parser[0x8] = function(stream, flags, payload)
  local bytes = string.unpack(">I4", payload)
  local increment = bytes & 0x7fffffff
  if stream.id == 0 then
    stream.connection.window = stream.connection.window + increment
  else
    stream.window = stream.window + increment
  end
end

-- CONTINUATION frame parser
frame_parser[0x9] = function(stream, flags, payload)
end

function mt.__index:send_window_update(size)
  local conn = self.connection
  conn.send_frame(conn, 0x8, 0x0, self.id, string.pack(">I4", size))
end

function mt.__index:send_headers(headers, body)
  local conn = self.connection
  local header_block = hpack.encode(conn.hpack_context, headers)
  if body then
    local fsize = conn.server_settings.MAX_FRAME_SIZE
    for i = 1, #body, fsize do
      if i + fsize >= #body then
        conn.send_frame(conn, 0x0, 0x1, self.id, string.sub(body, i))
      else
        conn.send_frame(conn, 0x0, 0x0, self.id, string.sub(body, i, i + fsize - 1))
      end
    end
  else
    conn.send_frame(conn, 0x1, 0x4 | 0x1, self.id, header_block)
  end
end

function mt.__index:get_headers()
  local conn = self.connection
  while  #self.headers == 0 do
    local ftype, flags, stream_id, payload = conn.recv_frame(conn)
    local s = conn.streams[stream_id]
    local parser = frame_parser[ftype]
    local res = parser(s, flags, payload)
  end
end

function mt.__index:get_body()
  local body = {}
  local i = 0
  local k = -1
  for _ in pairs(self.connection.streams) do k = k + 1 end
  while true do
    local ftype, flags, stream_id, data_payload = self.connection.recv_frame(self.connection)
    s = self.connection.streams[stream_id]
    local parser = frame_parser[ftype]
    local data = parser(s, flags, data_payload)
    if flags == 0x01 then i = i + 1 end
    if i == k then break end
  end
  while #self.data > 0 do
    table.insert(body, table.remove(self.data, 1))
  end
  return table.concat(body)
end

local function new(connection)
  local stream = setmetatable({
    connection = connection,
    state = "idle",
    id = nil,
    parent = nil,
    data = {},
    headers = {},
    window = 65535
  }, mt)
  return stream
end

local stream = {
  new = new,
  frame_parser = frame_parser
}

return stream
