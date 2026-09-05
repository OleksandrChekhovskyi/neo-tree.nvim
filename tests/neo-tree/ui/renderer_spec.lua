local u = require("tests.utils")

local test = u.fs.init_test({
  items = {
    { name = "foo", type = "dir" },
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

  test.teardown()
end)
