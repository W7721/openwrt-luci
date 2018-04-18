-- Copyright 2008 Steven Barth <steven@midlink.org>
-- Licensed to the public under the Apache License 2.0.

local ltn12 = require "luci.ltn12"
local protocol = require "luci.http.protocol"
local util  = require "luci.util"
local string = require "string"
local coroutine = require "coroutine"
local table = require "table"
local lhttp = require "lucihttp"

local ipairs, pairs, next, type, tostring, error =
	ipairs, pairs, next, type, tostring, error

module "luci.http"

context = util.threadlocal()

Request = util.class()
function Request.__init__(self, env, sourcein, sinkerr)
	self.input = sourcein
	self.error = sinkerr


	-- File handler nil by default to let .content() work
	self.filehandler = nil

	-- HTTP-Message table
	self.message = {
		env = env,
		headers = {},
		params = protocol.urldecode_params(env.QUERY_STRING or ""),
	}

	self.parsed_input = false
end

function Request.formvalue(self, name, noparse)
	if not noparse and not self.parsed_input then
		self:_parse_input()
	end

	if name then
		return self.message.params[name]
	else
		return self.message.params
	end
end

function Request.formvaluetable(self, prefix)
	local vals = {}
	prefix = prefix and prefix .. "." or "."

	if not self.parsed_input then
		self:_parse_input()
	end

	local void = self.message.params[nil]
	for k, v in pairs(self.message.params) do
		if k:find(prefix, 1, true) == 1 then
			vals[k:sub(#prefix + 1)] = tostring(v)
		end
	end

	return vals
end

function Request.content(self)
	if not self.parsed_input then
		self:_parse_input()
	end

	return self.message.content, self.message.content_length
end

function Request.getcookie(self, name)
	return lhttp.header_attribute("cookie; " .. (self:getenv("HTTP_COOKIE") or ""), name)
end

function Request.getenv(self, name)
	if name then
		return self.message.env[name]
	else
		return self.message.env
	end
end

function Request.setfilehandler(self, callback)
	self.filehandler = callback

	if not self.parsed_input then
		return
	end

	-- If input has already been parsed then uploads are stored as unlinked
	-- temporary files pointed to by open file handles in the parameter
	-- value table. Loop all params, and invoke the file callback for any
	-- param with an open file handle.
	local name, value
	for name, value in pairs(self.message.params) do
		if type(value) == "table" then
			while value.fd do
				local data = value.fd:read(1024)
				local eof = (not data or data == "")

				callback(value, data, eof)

				if eof then
					value.fd:close()
					value.fd = nil
				end
			end
		end
	end
end

function Request._parse_input(self)
	protocol.parse_message_body(
		 self.input,
		 self.message,
		 self.filehandler
	)
	self.parsed_input = true
end

function close()
	if not context.eoh then
		context.eoh = true
		coroutine.yield(3)
	end

	if not context.closed then
		context.closed = true
		coroutine.yield(5)
	end
end

function content()
	return context.request:content()
end

function formvalue(name, noparse)
	return context.request:formvalue(name, noparse)
end

function formvaluetable(prefix)
	return context.request:formvaluetable(prefix)
end

function getcookie(name)
	return context.request:getcookie(name)
end

-- or the environment table itself.
function getenv(name)
	return context.request:getenv(name)
end

function setfilehandler(callback)
	return context.request:setfilehandler(callback)
end

function header(key, value)
	if not context.headers then
		context.headers = {}
	end
	context.headers[key:lower()] = value
	coroutine.yield(2, key, value)
end

function prepare_content(mime)
	if not context.headers or not context.headers["content-type"] then
		if mime == "application/xhtml+xml" then
			if not getenv("HTTP_ACCEPT") or
			  not getenv("HTTP_ACCEPT"):find("application/xhtml+xml", nil, true) then
				mime = "text/html; charset=UTF-8"
			end
			header("Vary", "Accept")
		end
		header("Content-Type", mime)
	end
end

function source()
	return context.request.input
end

function status(code, message)
	code = code or 200
	message = message or "OK"
	context.status = code
	coroutine.yield(1, code, message)
end

-- This function is as a valid LTN12 sink.
-- If the content chunk is nil this function will automatically invoke close.
function write(content, src_err)
	if not content then
		if src_err then
			error(src_err)
		else
			close()
		end
		return true
	elseif #content == 0 then
		return true
	else
		if not context.eoh then
			if not context.status then
				status()
			end
			if not context.headers or not context.headers["content-type"] then
				header("Content-Type", "text/html; charset=utf-8")
			end
			if not context.headers["cache-control"] then
				header("Cache-Control", "no-cache")
				header("Expires", "0")
			end
			if not context.headers["x-frame-options"] then
				header("X-Frame-Options", "SAMEORIGIN")
			end
			if not context.headers["x-xss-protection"] then
				header("X-XSS-Protection", "1; mode=block")
			end
			if not context.headers["x-content-type-options"] then
				header("X-Content-Type-Options", "nosniff")
			end

			context.eoh = true
			coroutine.yield(3)
		end
		coroutine.yield(4, content)
		return true
	end
end

function splice(fd, size)
	coroutine.yield(6, fd, size)
end

function redirect(url)
	if url == "" then url = "/" end
	status(302, "Found")
	header("Location", url)
	close()
end

function build_querystring(q)
	local s, n, k, v = {}, 1, nil, nil

	for k, v in pairs(q) do
		s[n+0] = (n == 1) and "?" or "&"
		s[n+1] = util.urlencode(k)
		s[n+2] = "="
		s[n+3] = util.urlencode(v)
		n = n + 4
	end

	return table.concat(s, "")
end

urldecode = util.urldecode

urlencode = util.urlencode

function write_json(x)
	util.serialize_json(x, write)
end
