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
local function show_tree(root)
  require("neo-tree").setup({
    enable_git_status = true,
    filesystem = {
      use_libuv_file_watcher = true,
      filtered_items = { hide_gitignored = false },
    },
  })
  require("neo-tree.command").execute({ action = "show", source = "filesystem", dir = root })
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
end)
