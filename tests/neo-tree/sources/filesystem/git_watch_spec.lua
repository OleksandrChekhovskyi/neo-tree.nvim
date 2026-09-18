pcall(require, "luacov")

local u = require("tests.utils")
local uv = vim.uv or vim.loop
local verify = require("tests.utils.verify")
local git = require("neo-tree.git")
local utils = require("neo-tree.utils")

-- Registration spawns `git rev-parse` and `git status`, which is slow on CI runners.
local TIMEOUT = 30 * 1000

---@param cwd string
---@param ... string
local function git_cmd(cwd, ...)
  local output = vim.fn.system(vim.list_extend({
    "git",
    "-C",
    cwd,
    -- commit-tree needs an identity, and the test must not depend on the user having one.
    "-c",
    "user.name=Test",
    "-c",
    "user.email=test@example.invalid",
    -- The first ref update of a repository creates the reflog directory, which is a
    -- change to the git dir itself and would hide a missing watcher on the refs.
    "-c",
    "core.logallrefupdates=false",
  }, { ... }))
  assert(vim.v.shell_error == 0, "git " .. table.concat({ ... }, " ") .. " failed in " .. cwd)
  return vim.trim(output)
end

---@param path string
---@return string
local function normalize(path)
  return utils.normalize_path(assert(uv.fs_realpath(path)))
end

---A repository with one staged file and a tree object written for it. Committing that
---tree later moves the branch without touching the git dir itself, which is exactly
---what a watcher on the git dir alone cannot see.
---@return string root, string file, string tree
local function create_repo_with_written_tree()
  local root = u.fs.create_temp_dir()
  git_cmd(root, "init", "--quiet")
  local file = utils.path_join(root, "staged.txt")
  u.fs.write_file(file, { "hello" })
  git_cmd(root, "add", "staged.txt")
  local tree = git_cmd(root, "write-tree")
  return normalize(root), normalize(file), tree
end

---@param root string
---@param reveal_file string? Expands the path down to it, registering repositories on the way.
local function show_tree(root, reveal_file)
  require("neo-tree").setup({
    enable_git_status = true,
    filesystem = {
      use_libuv_file_watcher = true,
      filtered_items = { hide_gitignored = false },
    },
  })
  require("neo-tree.command").execute({
    action = "show",
    source = "filesystem",
    dir = root,
    reveal_file = reveal_file,
  })
end

---@param file string
---@param expected string?
local function verify_status_becomes(file, expected)
  verify.eventually(function()
    return git.find_existing_status_code(file, {}) == expected
  end, function()
    return ("status for %s is %s, expected %s"):format(
      file,
      vim.inspect(git.find_existing_status_code(file, {})),
      vim.inspect(expected)
    )
  end, TIMEOUT)
end

describe("Filesystem git status watching", function()
  -- The temporary repositories are deliberately left on disk. Removing them while an
  -- async `git status` is still in flight makes it fail against a missing directory,
  -- and Neovim drops its own temp directory on exit anyway.
  after_each(function()
    u.clear_environment()
  end)

  it("refreshes when a commit only moves the branch", function()
    local root, file, tree = create_repo_with_written_tree()
    show_tree(root)
    verify_status_becomes(file, "A.")

    local commit = git_cmd(root, "commit-tree", tree, "-m", "commit")
    git_cmd(root, "update-ref", "HEAD", commit)

    verify_status_becomes(file, nil)
  end)

  it("refreshes a linked worktree, whose refs live in the common dir", function()
    local root = create_repo_with_written_tree()
    local commit = git_cmd(root, "commit-tree", git_cmd(root, "write-tree"), "-m", "commit")
    git_cmd(root, "update-ref", "HEAD", commit)

    local linked = utils.path_join(root, "linked")
    git_cmd(root, "worktree", "add", "--quiet", "-b", "linked", linked)
    local file = utils.path_join(linked, "staged.txt")
    u.fs.write_file(file, { "goodbye" })
    git_cmd(linked, "add", "staged.txt")
    local tree = git_cmd(linked, "write-tree")
    linked, file = normalize(linked), normalize(file)

    show_tree(linked)
    verify_status_becomes(file, "M.")

    local linked_commit = git_cmd(linked, "commit-tree", tree, "-p", commit, "-m", "commit")
    git_cmd(linked, "update-ref", "HEAD", linked_commit)

    verify_status_becomes(file, nil)
  end)

  it("does not retain modifications committed between the fast and full status", function()
    local root, file = create_repo_with_written_tree()
    git_cmd(root, "commit", "--quiet", "-m", "initial")
    u.fs.write_file(file, { "modified" })
    show_tree(root)
    local amended = false
    require("neo-tree.events").subscribe({
      event = require("neo-tree.events").BEFORE_GIT_STATUS,
      handler = function(args)
        if
          args.git_root == root
          and vim.tbl_contains(args.status_args, "--untracked-files=normal")
          and not amended
        then
          amended = true
          -- Commit in the status subprocess, after the fast result has been parsed.
          for i, arg in ipairs(args.status_args) do
            if arg == "status" then
              args.status_args[i] = "test-amend-status"
              table.insert(
                args.status_args,
                i,
                "alias.test-amend-status="
                  .. "!git -c user.name=Test -c user.email=test@example.invalid"
                  .. " commit --quiet -a --amend --no-edit && git status"
              )
              table.insert(args.status_args, i, "-c")
              break
            end
          end
        end
      end,
    })
    verify.eventually(function()
      return amended
    end, "full status did not run", TIMEOUT)
    verify_status_becomes(file, nil)
    assert.are.equal("", git_cmd(root, "status", "--porcelain"))
  end)

  it("refreshes a repository below the tree root", function()
    local parent = normalize(u.fs.create_temp_dir())
    local root = utils.path_join(parent, "nested")
    vim.fn.mkdir(root, "p")
    git_cmd(root, "init", "--quiet")
    local file = utils.path_join(root, "tracked.txt")
    u.fs.write_file(file, { "hello" })
    git_cmd(root, "add", "tracked.txt")
    git_cmd(root, "commit", "--quiet", "-m", "initial")
    root, file = normalize(root), normalize(file)

    -- The tree is rooted above the repository, so refreshing runs a status for the
    -- root's own worktree, which is none. Nothing but the repository that fired the
    -- event can refresh this one.
    show_tree(parent, file)
    u.fs.write_file(file, { "modified" })
    verify.eventually(function()
      return git.find_existing_status_code(file, {}) ~= nil
    end, "the nested repository never reported the file as modified", TIMEOUT)

    git_cmd(root, "commit", "--quiet", "-a", "-m", "commit")
    verify_status_becomes(file, nil)
  end)

  it("does not let an outdated status run land on top of a newer one", function()
    local fast = { batch_size = 1000, batch_delay = 10, max_lines = 100000 }
    -- One entry per batch, so this run is still parsing long after the next one has
    -- reported. A run's output is cached when the process exits, but its result is
    -- only applied when the parse ends, which is what lets the two disagree.
    local slow = { batch_size = 1, batch_delay = 150, max_lines = 100000 }

    -- No watchers, so the only status runs are the ones this test asks for.
    require("neo-tree").setup({
      enable_git_status = true,
      filesystem = {
        use_libuv_file_watcher = false,
        filtered_items = { hide_gitignored = false },
      },
    })

    local root = normalize(u.fs.create_temp_dir())
    git_cmd(root, "init", "--quiet")
    local files = {}
    for i = 1, 15 do
      local path = utils.path_join(root, ("tracked%d.txt"):format(i))
      u.fs.write_file(path, { "hello" })
      files[#files + 1] = normalize(path)
    end
    git_cmd(root, "add", "-A")
    git_cmd(root, "commit", "--quiet", "-m", "initial")
    local file = files[1]

    u.fs.write_file(file, { "modified" })
    git.status_async(root, nil, fast)
    verify.eventually(function()
      return git.find_existing_status_code(file, {}) ~= nil
    end, "the modification was never picked up", TIMEOUT)
    vim.wait(1100) -- past the per-worktree debounce, so the next call runs at once

    -- Dirty the rest too, so this run's output differs from the cached one and it
    -- has enough entries to keep parsing for a while.
    for _, path in ipairs(files) do
      u.fs.write_file(path, { "modified" })
    end
    git.status_async(root, nil, slow)

    -- Long enough for that run's `git status` to have captured the dirty tree and
    -- exited, far short of the time its parse needs.
    vim.wait(500)
    git_cmd(root, "commit", "--quiet", "-a", "-m", "commit")
    vim.wait(600)
    git.status_async(root, nil, fast)

    verify_status_becomes(file, nil)
    -- The slow run reports here. It must neither restore its own stale result nor
    -- leave the cached output describing a status that was never applied, which is
    -- what used to make a stale status permanent.
    vim.wait(4000)
    assert.are.equal("", git_cmd(root, "status", "--porcelain"))
    assert.is_nil(git.find_existing_status_code(file, {}))

    git.status_async(root, nil, fast)
    verify_status_becomes(file, nil)
  end)

  it("keeps its watchers across a rescan of the tree", function()
    local watch = require("neo-tree.git.watch")
    local root, file = create_repo_with_written_tree()
    show_tree(root)
    verify_status_becomes(file, "A.")

    local watched = vim.deepcopy(assert(git.worktrees[root]).watched_dirs)
    assert.is_true(#watched > 0)
    local handles = vim.tbl_map(function(watcher)
      return watcher.handle
    end, watch._watchers(root))

    -- Rescanning releases the watchers of every directory in the tree. Git dirs are
    -- not the tree's to release: dropping them, even for the length of one scan,
    -- loses whatever git writes in between.
    local state = require("neo-tree.sources.manager").get_state("filesystem")
    require("neo-tree.sources.filesystem.lib.fs_scan").stop_watchers(state)
    require("neo-tree.sources.filesystem.lib.fs_watch").updated_watched()

    assert.are.same(watched, assert(git.worktrees[root]).watched_dirs)
    for i, watcher in ipairs(watch._watchers(root)) do
      assert.are.equal(handles[i], watcher.handle)
      assert.is_false(watcher.handle:is_closing())
    end
  end)

  it("reuses watchers when asked to watch again, and closes them on unwatch", function()
    local watch = require("neo-tree.git.watch")
    local root = create_repo_with_written_tree()
    local git_dir = normalize(git_cmd(root, "rev-parse", "--absolute-git-dir"))

    local watched = watch.watch(root, git_dir)
    assert.is_true(#watched > 0)
    local handles = vim.tbl_map(function(watcher)
      return watcher.handle
    end, watch._watchers(root))

    -- Every status refresh watches again; that must reconcile the set rather than
    -- open a second handle per directory.
    for _ = 1, 3 do
      assert.are.same(watched, watch.watch(root, git_dir))
    end
    for i, watcher in ipairs(watch._watchers(root)) do
      assert.are.equal(handles[i], watcher.handle)
    end

    watch.unwatch(root)
    assert.are.same({}, watch._watchers(root))
    for _, handle in ipairs(handles) do
      assert.is_true(handle:is_closing())
    end
  end)
end)
