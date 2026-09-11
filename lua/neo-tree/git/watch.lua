local git = require("neo-tree.git")
local utils = require("neo-tree.utils")
local fs_watch = require("neo-tree.sources.filesystem.lib.fs_watch")
local events = require("neo-tree.events")
local log = require("neo-tree.log")
local uv = vim.uv or vim.loop
local M = {}

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

---Directories whose direct children describe the state `git status` reports. The
---index and HEAD live in the git dir, but the branch tip lives under refs/ in the
---common dir, so a commit that only moves the branch is invisible to a watcher on
---the git dir alone. https://git-scm.com/docs/gitrepository-layout
---@param git_dir string
---@return string[] dirs
local status_dirs = function(git_dir)
  local common_dir = find_common_dir(git_dir)
  local dirs = { git_dir, utils.path_join(common_dir, "reftable") }
  if common_dir ~= git_dir then
    -- packed-refs and the loose refs of every worktree live here
    dirs[#dirs + 1] = common_dir
  end
  local head = read_metadata(utils.path_join(git_dir, "HEAD"))
  local ref = head and head:match("^ref:%s*(%S+)")
  if ref then
    local ref_dir = vim.split(vim.fs.dirname(ref), "/")
    dirs[#dirs + 1] = utils.path_join(common_dir, unpack(ref_dir))
  end
  return vim.tbl_filter(function(dir)
    local stat = uv.fs_stat(dir)
    return stat ~= nil and stat.type == "directory"
  end, dirs)
end

---@param worktree_root string?
---@param git_dir string?
---@return string[] watched_dirs Every directory now watched for this worktree.
M.watch = function(worktree_root, git_dir)
  if not git_dir or not worktree_root then
    return {}
  end
  local callback = function(err, fname)
    if fname then
      if vim.endswith(fname, ".lock") then
        return
      end
      if fname:find("_null-ls_", 1, true) then
        -- null-ls temp file: https://github.com/jose-elias-alvarez/null-ls.nvim/pull/1075
        return
      end
    end

    if err then
      log.error("git_event_callback: ", err)
      return
    end
    utils.debounce("git_folder_exists " .. git_dir, function()
      local git_folder_stat = uv.fs_stat(git_dir)
      if git_folder_stat and git_folder_stat.type == "directory" then
        return
      end

      git.find_worktree_info(git_dir)
    end, 5000, utils.debounce_strategy.CALL_LAST_ONLY)

    vim.schedule(function()
      events.fire_event(events.GIT_EVENT)
    end)
  end

  local watched_dirs = {}
  for _, dir in ipairs(status_dirs(git_dir)) do
    if fs_watch.watch_folder(dir, callback) then
      watched_dirs[#watched_dirs + 1] = dir
    end
  end
  fs_watch.updated_watched()
  return watched_dirs
end

return M
