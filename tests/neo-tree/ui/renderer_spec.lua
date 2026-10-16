local u = require("tests.utils")

local test = u.fs.init_test({
  items = {
    {
      name = "foo",
      type = "dir",
      items = {
        {
          name = "sub",
          type = "dir",
          items = {
            { name = "a.txt", type = "file", id = "sub_a" },
            { name = "b.txt", type = "file", id = "sub_b" },
          },
        },
      },
    },
    { name = "bar.txt", type = "file" },
  },
})

describe("UI renderer", function()
  local original_defer_fn
  local resize_timers
  local resize_timer_interval = 60000

  test.setup()

  before_each(function()
    original_defer_fn = vim.defer_fn
    resize_timers = {}
    vim.defer_fn = function(fn, timeout)
      local timer = original_defer_fn(fn, timeout)
      if timeout == resize_timer_interval then
        resize_timers[#resize_timers + 1] = timer
      end
      return timer
    end
  end)

  after_each(function()
    vim.defer_fn = original_defer_fn
    for _, timer in ipairs(resize_timers) do
      if not timer:is_closing() then
        timer:stop()
        timer:close()
      end
    end
    u.clear_environment()
  end)

  it("starts only one resize monitor across repeated draws", function()
    require("neo-tree").setup({
      enable_diagnostics = false,
      enable_git_status = false,
      resize_timer_interval = resize_timer_interval,
      sources = { "filesystem" },
    })
    vim.cmd.Neotree("filesystem", "focus")
    u.wait_for_neo_tree()

    local filesystem = require("neo-tree.sources.filesystem")
    local state = require("neo-tree.sources.manager").get_state("filesystem")
    for _ = 1, 3 do
      local complete = false
      filesystem._navigate_internal(state, nil, nil, function()
        complete = true
      end, false)
      u.wait_for(function()
        return complete
      end)
    end

    u.eq(1, #resize_timers)
  end)

  describe("a redraw before a navigation is drawn", function()
    local filesystem, renderer, state

    before_each(function()
      require("neo-tree").setup({
        enable_diagnostics = false,
        enable_git_status = false,
        sources = { "filesystem" },
      })
      vim.cmd.Neotree("filesystem", "focus")
      u.wait_for_neo_tree()
      filesystem = require("neo-tree.sources.filesystem")
      renderer = require("neo-tree.ui.renderer")
      state = require("neo-tree.sources.manager").get_state("filesystem")
    end)

    ---Navigates, redrawing the tree being replaced before the new one is drawn, as a debounced
    ---event such as a git status or opened buffers change may.
    local navigate = function(path, path_to_reveal)
      local complete = false
      filesystem._navigate_internal(state, path, path_to_reveal, function()
        complete = true
      end, false)
      renderer.redraw(state)
      u.wait_for(function()
        return complete
      end)
    end

    local node_under_cursor = function()
      local node = state.tree:get_node(vim.api.nvim_win_get_cursor(state.winid)[1])
      return node and node:get_id()
    end

    it("still reveals a node the old tree does not have", function()
      local file = test.fs_tree.lookup["sub_b"].abspath
      navigate(vim.fs.dirname(file), file)
      u.eq(file, node_under_cursor())
    end)

    it("reveals a node where the new tree has it, not where the old one did", function()
      local file = test.fs_tree.lookup["sub_b"].abspath
      local sub = vim.fs.dirname(file)
      navigate(sub, file)
      u.eq(file, node_under_cursor())
      navigate(vim.fs.dirname(sub), file)
      u.eq(file, node_under_cursor())
    end)
  end)

  test.teardown()
end)
