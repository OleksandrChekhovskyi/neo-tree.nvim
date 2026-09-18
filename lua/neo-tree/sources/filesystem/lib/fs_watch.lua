local events = require("neo-tree.events")
local log = require("neo-tree.log")
local uv = vim.uv or vim.loop

local M = {}

local flags = {
  watch_entry = false,
  stat = false,
  recursive = false,
}

---@type table<string, neotree.sources.filesystem.Watcher?>
local watchers = {}

M.show_watched = function()
  local items = {}
  for p, handle in pairs(watchers) do
    items[p] = handle.references
  end
  log.info("Watched Folders: ", vim.inspect(items))
end

---@class neotree.sources.filesystem.WatcherOpts
---@field handle uv.uv_fs_event_t?
---@field references integer
---@field active boolean
---@field callback fun(err: string?, name: string)

---@class neotree.sources.filesystem.Watcher : neotree.sources.filesystem.WatcherOpts
local Watcher = {}

---@param opts neotree.sources.filesystem.WatcherOpts
function Watcher:new(opts)
  setmetatable(opts, self)
  self.__index = self
  ---@cast opts neotree.sources.filesystem.Watcher
  return opts
end

---Idempotently start the watcher on the path
---@param path string
---@return boolean started
function Watcher:start(path)
  if self.active then
    return true
  end
  if not self.handle then
    local handle, err = uv.new_fs_event()
    if not handle then
      log.debug("Can't make fs event:", err)
      return false
    end
    self.handle = handle
  end
  self.handle:start(path, flags, function(err, fname)
    if err == "EPERM" then
      self:stop()
    end
    self.callback(err, fname)
  end)
  self.active = true
  return true
end

---Stops watching and releases the handle. libuv holds a stopped handle until it is
---closed, so a session that browses many directories would otherwise pile them up
---for the rest of its life.
function Watcher:stop()
  if self.handle and not self.handle:is_closing() then
    self.handle:stop()
    self.handle:close()
  end
  self.handle = nil
  self.active = false
end

---Watch a directory for changes to it's children. Not recursive.
---@param path string The directory to watch.
---@param callback fun(err: string?, fname: string) The callback to call when a change is detected.
---@return neotree.sources.filesystem.Watcher?
M.watch_folder = function(path, callback)
  local w = watchers[path]
  if w then
    log.trace("Incrementing references for fs watch on:", path)
    w.references = w.references + 1
    return w
  end
  log.trace("Creating new fs watch on:", path)
  -- The handle is made on start, so that a watcher which has been stopped and later
  -- wanted again gets a fresh one instead of holding a closed handle.
  w = Watcher:new({
    references = 1,
    active = false,
    callback = callback,
  })
  log.trace("Incrementing references for fs watch on:", path)
  watchers[path] = w
  return w
end

M.updated_watched = function()
  for path, w in pairs(watchers) do
    if w.references > 0 then
      log.trace("References added for fs watch on:", path, ", starting.")
      w:start(path)
    else
      log.trace("No more references for fs watch on:", path, ", stopping.")
      w:stop()
      -- Dropping it here keeps the registry proportional to what is being watched
      -- rather than to every directory this session has ever visited.
      watchers[path] = nil
    end
  end
end

---Stop watching a directory. If there are no more references to the handle,
---it will eventually be destroyed. Otherwise, the reference count will be decremented.
---@param path string The directory to stop watching.
M.unwatch_folder = function(path, callback_id)
  local w = watchers[path]
  if w then
    log.trace("Decrementing references for fs watch on:", path, callback_id)
    w.references = w.references - 1
  else
    log.trace("(unwatch_folder) No fs watch found for:", path)
  end
end

---Stop watching all directories. This is the nuclear option and it affects all
---sources.
M.stop_watching = function()
  for _, h in pairs(watchers) do
    h:stop()
  end
  watchers = {}
end

return M
