local Curl = require("plenary.curl")
local Path = require("plenary.path")
local config = require("codecompanion.config")
local log = require("codecompanion.utils.log")
local util = require("codecompanion.utils")

---@class CodeCompanion.Client
---@field adapter CodeCompanion.Adapter
---@field static table
---@field opts nil|table
---@field user_args nil|table
local Client = {}
Client.static = {}

-- This makes it easier to mock during testing
Client.static.opts = {
  post = { default = Curl.post },
  get = { default = Curl.get },
  encode = { default = vim.json.encode },
  schedule = { default = vim.schedule_wrap },
}

local function transform_static(opts)
  local ret = {}
  for k, v in pairs(Client.static.opts) do
    if opts and opts[k] ~= nil then
      ret[k] = opts[k]
    else
      ret[k] = v.default
    end
  end
  return ret
end

---@class CodeCompanion.ClientArgs
---@field adapter CodeCompanion.Adapter
---@field opts nil|table
---@field user_args nil|table

---@param args CodeCompanion.ClientArgs
---@return table
function Client.new(args)
  args = args or {}

  return setmetatable({
    adapter = args.adapter,
    opts = args.opts or transform_static(args.opts),
    user_args = args.user_args or {},
  }, { __index = Client })
end

---@class CodeCompanion.Adapter.RequestActions
---@field callback fun(err: nil|string, chunk: nil|table) Callback function, executed when the request has finished or is called multiple times if the request is streaming
---@field done? fun() Function to run when the request is complete

---Send a HTTP request
---@param payload { messages: table, tools: table|nil } The payload to be sent to the endpoint
---@param actions CodeCompanion.Adapter.RequestActions
---@param opts? table Options that can be passed to the request
---@return table|nil The Plenary job
function Client:request(payload, actions, opts)
  opts = opts or {}
  local cb = log:wrap_cb(actions.callback, "Response error: %s") --[[@type function]]

  -- Make a copy of the adapter to ensure that we replace variables in every request
  local adapter = vim.deepcopy(self.adapter)

  local handlers = adapter.handlers

  if handlers and handlers.setup then
    local ok = handlers.setup(adapter)
    if not ok then
      return log:error("Failed to setup adapter")
    end
  end

  adapter:get_env_vars()

 local body_components = {} -- Start as an empty table (dictionary)

  -- 1. Get formatted messages (expected to return { messages = {...} } or similar)
  if handlers.form_messages then
    local formatted_msgs_component = handlers.form_messages(adapter, payload.messages)
    if formatted_msgs_component and type(formatted_msgs_component) == "table" then
      for k, v in pairs(formatted_msgs_component) do
        body_components[k] = v
      end
    end
  end

  -- 2. Get formatted tools (expected to return { tools = {...} } or nil)
  if handlers.form_tools then
    local formatted_tools_component = handlers.form_tools(adapter, payload.tools)
    if formatted_tools_component and type(formatted_tools_component) == "table" then
      for k, v in pairs(formatted_tools_component) do
        body_components[k] = v
      end
    end
  end

  -- 3. Get formatted parameters (expected to return a flat table of parameters like { model="x", temperature=1, tool_choice="auto" })
  if handlers.form_parameters then
    local base_params = adapter:set_env_vars(adapter.parameters) or {} -- Ensure it's a table
    local tools_actually_being_sent = body_components.tools -- This is the array of tool schemas, or nil

    local final_params_component = handlers.form_parameters(
      adapter,
      base_params, -- Pass the initial parameters
      payload.messages,
      tools_actually_being_sent -- Pass the tools that will actually be in the body
    )
    if final_params_component and type(final_params_component) == "table" then
      for k, v in pairs(final_params_component) do
        body_components[k] = v
      end
    end
  end

  -- 4. Add other specific body components if they exist (e.g., adapter.body for custom top-level keys)
  if adapter.body and type(adapter.body) == "table" then
    for k, v in pairs(adapter.body) do
      body_components[k] = v
    end
  end

  -- 5. Allow handlers.set_body to potentially override or add anything (use with caution)
  if handlers.set_body then
     local set_body_component = handlers.set_body(adapter, payload)
     if set_body_component and type(set_body_component) == "table" then
        for k, v in pairs(set_body_component) do
          body_components[k] = v
        end
     end
  end

  -- Ensure essential components are present if expected by the API
  if not body_components.messages then
    log:warn("Request body is missing 'messages' component. This might be an error.")
    -- Depending on API strictness, you might need to ensure messages is always at least an empty array.
    -- However, most APIs require messages.
  end

  log:trace("Final body_components before encoding: %s", body_components)
  local body = self.opts.encode(body_components)

  local body_file = Path.new(vim.fn.tempname() .. ".json")
  body_file:write(vim.split(body, "\n"), "w")

  log:info("Request body file: %s", body_file.filename)

  local function cleanup(status)
    if vim.tbl_contains({ "ERROR", "INFO" }, config.opts.log_level) and status ~= "error" then
      body_file:rm()
    end
  end

  local raw = {
    "--retry",
    "3",
    "--retry-delay",
    "1",
    "--keepalive-time",
    "60",
    "--connect-timeout",
    "10",
  }

  if adapter.opts and adapter.opts.stream then
    table.insert(raw, "--tcp-nodelay")
    table.insert(raw, "--no-buffer")
  end

  if adapter.raw then
    vim.list_extend(raw, adapter:set_env_vars(adapter.raw))
  end

  local request_opts = {
    url = adapter:set_env_vars(adapter.url),
    headers = adapter:set_env_vars(adapter.headers),
    insecure = config.adapters.opts.allow_insecure,
    proxy = config.adapters.opts.proxy,
    raw = raw,
    body = body_file.filename or "",
    -- This is called when the request is finished. It will only ever be called
    -- once, even if the endpoint is streaming.
    callback = function(data)
      vim.schedule(function()
        if (not adapter.opts.stream) and data and data ~= "" then
          log:trace("Output data:\n%s", data)
          cb(nil, data, adapter)
        end
        if handlers and handlers.on_exit then
          handlers.on_exit(adapter, data)
        end
        if handlers and handlers.teardown then
          handlers.teardown(adapter)
        end
        if actions.done and type(actions.done) == "function" then
          actions.done()
        end

        opts.status = "success"
        if data.status >= 400 then
          opts.status = "error"
        end

        if not opts.silent then
          util.fire("RequestFinished", opts)
        end
        cleanup(opts.status)
        if self.user_args.event then
          if not opts.silent then
            util.fire("RequestFinished" .. (self.user_args.event or ""), opts)
          end
        end
      end)
    end,
    on_error = function(err)
      vim.schedule(function()
        actions.callback(err, nil)
        if not opts.silent then
          util.fire("RequestFinished", opts)
        end
      end)
    end,
  }

  if adapter.opts and adapter.opts.stream then
    local has_started_steaming = false

    -- Turn off plenary's default compression
    request_opts["compressed"] = adapter.opts.compress or false

    -- This will be called multiple times until the stream is finished
    request_opts["stream"] = self.opts.schedule(function(_, data)
      if data and data ~= "" then
        log:trace("Output data:\n%s", data)
      end
      if not has_started_steaming then
        has_started_steaming = true
        if not opts.silent then
          util.fire("RequestStreaming", opts)
        end
      end
      cb(nil, data, adapter)
    end)
  end

  local request = "post"
  if adapter.opts and adapter.opts.method then
    request = adapter.opts.method:lower()
  end

  local job = self.opts[request](request_opts)

  -- Data to be sent via the request
  opts.id = math.random(10000000)
  opts.adapter = {
    name = adapter.name,
    formatted_name = adapter.formatted_name,
    model = type(adapter.schema.model.default) == "function" and adapter.schema.model.default()
      or adapter.schema.model.default
      or "",
  }

  if not opts.silent then
    util.fire("RequestStarted", opts)
  end

  if job and job.args then
    log:debug("Request:\n%s", job.args)
  end
  if self.user_args.event then
    if not opts.silent then
      util.fire("RequestStarted" .. (self.user_args.event or ""), opts)
    end
  end

  return job
end

return Client
