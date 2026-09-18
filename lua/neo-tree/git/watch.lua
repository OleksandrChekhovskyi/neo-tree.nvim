local utils = require("neo-tree.utils")
local events = require("neo-tree.events")
local log = require("neo-tree.log")
local uv = vim.uv or vim.loop
local M = {}

---Files directly in a git dir whose contents decide what `git status` reports.
---Everything else written there is either irrelevant (COMMIT_EDITMSG, logs, loose
---objects) or a transient lock, and waking up for those only buys a `git status`
---against a state git has not finished writing yet.
---https://git-scm.com/docs/gitrepository-layout
local status_files = {
  HEAD = true,
  ORIG_HEAD = true,
  MERGE_HEAD = true,
  CHERRY_PICK_HEAD = true,
  REVERT_HEAD = true,
  REBASE_HEAD = true,
  index = true,
  config = true,
  ["packed-refs"] = true,
}

---Reads one of git's small metadata files. Runs in libuv callbacks, so it cannot
---use vim.fn.
---@param path string
---@return string? contents
local read_metadata = function(path)
  local fd = uv.fs_open(path, "r", 420)
  if not fd then
    return nil
  end
  local stat = uv.fs_fstat(fd)
  local contents = stat and uv.fs_read(fd, stat.size, 0) or nil
  uv.fs_close(fd)
  return contents
end

---A linked worktree keeps HEAD and the index in its own git dir but shares refs
---through the common dir, which its "commondir" file points at.
---@param git_dir string
---@return string common_dir
local find_common_dir = function(git_dir)
  local pointer = read_metadata(utils.path_join(git_dir, "commondir"))
  if not pointer then
    return git_dir
  end
  local path = vim.trim(pointer)
  local drive, root = utils.path_splitroot(path)
  if drive ~= "" or root ~= "" then
    return utils.normalize_path(path)
  end
  return utils.normalize_path(vim.fs.normalize(utils.path_join(git_dir, path)))
end

---@class (private) neotree.git.watch.Dir
---@field path string
---@field refs boolean Whether its children are ref names rather than known git files.

---Directories whose direct children describe the state `git status` reports. The
---index and HEAD live in the git dir, but the branch tip lives under refs/ in the
---common dir, so a commit that only moves the branch is invisible to a watcher on
---the git dir alone.
---@param git_dir string
---@return neotree.git.watch.Dir[] dirs
local status_dirs = function(git_dir)
  local common_dir = find_common_dir(git_dir)
  local dirs = {
    { path = git_dir, refs = false },
    { path = utils.path_join(common_dir, "reftable"), refs = true },
  }
  if common_dir ~= git_dir then
    -- packed-refs and the loose refs of every worktree live here
    dirs[#dirs + 1] = { path = common_dir, refs = false }
  end
  local head = read_metadata(utils.path_join(git_dir, "HEAD"))
  local ref = head and head:match("^ref:%s*(%S+)")
  if ref then
    local ref_dir = vim.split(vim.fs.dirname(ref), "/")
    dirs[#dirs + 1] = { path = utils.path_join(common_dir, unpack(ref_dir)), refs = true }
  end
  return vim.tbl_filter(function(dir)
    local stat = uv.fs_stat(dir.path)
    return stat ~= nil and stat.type == "directory"
  end, dirs)
end

---Ref directories hold arbitrary branch names, so everything there counts; the git
---dir itself is mostly noise, so only the files a status depends on do.
---@param dir neotree.git.watch.Dir
---@param fname string?
---@return boolean
local affects_status = function(dir, fname)
  if not fname then
    -- The watched directory itself changed, e.g. the git dir was removed.
    return true
  end
  if vim.endswith(fname, ".lock") then
    return false
  end
  return dir.refs or status_files[fname] == true
end

---@class (private) neotree.git.watch.Watcher
---@field path string
---@field handle uv.uv_fs_event_t

---Watchers are held per worktree rather than per render, so they outlive refreshes.
---@type table<string, neotree.git.watch.Watcher[]?>
local watchers_by_worktree = {}

---@param watcher neotree.git.watch.Watcher
local release = function(watcher)
  if not watcher.handle:is_closing() then
    watcher.handle:stop()
    -- libuv holds a stopped handle until it is closed.
    watcher.handle:close()
  end
end

---@param dir neotree.git.watch.Dir
---@param worktree_root string
---@param git_dir string
---@return neotree.git.watch.Watcher?
local start_watcher = function(dir, worktree_root, git_dir)
  local handle, new_err = uv.new_fs_event()
  if not handle then
    log.debug("Can't make fs event for", dir.path, ":", new_err)
    return nil
  end

  local started, start_err = handle:start(dir.path, {}, function(err, fname)
    if err then
      log.error("git_event_callback: ", err)
      return
    end
    if not affects_status(dir, fname) then
      return
    end

    utils.debounce("git_folder_exists " .. git_dir, function()
      local git_folder_stat = uv.fs_stat(git_dir)
      if git_folder_stat and git_folder_stat.type == "directory" then
        return
      end

      require("neo-tree.git").find_worktree_info(git_dir)
    end, 5000, utils.debounce_strategy.CALL_LAST_ONLY)

    vim.schedule(function()
      ---Naming the repository lets a source refresh the worktree that actually
      ---changed, which is not always the one its tree is rooted in.
      ---@class neotree.event.args.GIT_EVENT
      local args = {
        git_root = worktree_root,
      }
      events.fire_event(events.GIT_EVENT, args)
    end)
  end)

  if not started then
    log.debug("Can't watch", dir.path, ":", start_err)
    handle:close()
    return nil
  end

  return { path = dir.path, handle = handle }
end

---Watches everything `git status` depends on for a worktree. Idempotent: it keeps
---the watchers that are still wanted and releases the rest, so it can be called on
---every status refresh to pick up a ref directory HEAD has moved to.
---
---These watchers belong to the worktree, not to a render. Releasing them between
---refreshes would drop every event git writes in the meantime, and inotify does not
---replay what it missed.
---@param worktree_root string?
---@param git_dir string?
---@return string[] watched_dirs Every directory now watched for this worktree.
M.watch = function(worktree_root, git_dir)
  if not git_dir or not worktree_root then
    return {}
  end

  local unwanted = {}
  for _, watcher in ipairs(watchers_by_worktree[worktree_root] or {}) do
    unwanted[watcher.path] = watcher
  end

  local kept, paths = {}, {}
  for _, dir in ipairs(status_dirs(git_dir)) do
    local watcher = unwanted[dir.path]
    if watcher then
      unwanted[dir.path] = nil
    else
      watcher = start_watcher(dir, worktree_root, git_dir)
    end
    if watcher then
      kept[#kept + 1] = watcher
      paths[#paths + 1] = watcher.path
    end
  end

  for _, watcher in pairs(unwanted) do
    release(watcher)
  end

  watchers_by_worktree[worktree_root] = kept
  return paths
end

---Releases every watcher held for a worktree. Only for a worktree that is going
---away: a refresh must never do this.
---@param worktree_root string
M.unwatch = function(worktree_root)
  for _, watcher in ipairs(watchers_by_worktree[worktree_root] or {}) do
    release(watcher)
  end
  watchers_by_worktree[worktree_root] = nil
end

M.unwatch_all = function()
  for worktree_root in pairs(watchers_by_worktree) do
    M.unwatch(worktree_root)
  end
end

---@param worktree_root string
---@return neotree.git.watch.Watcher[]
M._watchers = function(worktree_root)
  return watchers_by_worktree[worktree_root] or {}
end

return M
