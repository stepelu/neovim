local t = require('test.testutil')
local n = require('test.functional.testnvim')()
local Screen = require('test.functional.ui.screen')

local describe, it, before_each = t.describe, t.it, t.before_each
local eq = t.eq
local api = n.api
local command = n.command
local exec_lua = n.exec_lua
local feed = n.feed

describe('Normal mode refresh', function()
  local screen
  local down = string.rep('j', 9)

  local function expect_view(topline, curline)
    screen:expect(function()
      local view = screen.win_viewport[2]
      eq({ topline, curline }, { view.topline, view.curline })
    end)
  end

  local function setup()
    n.clear()
    screen = Screen.new(20, 6, { ext_multigrid = true })
    command(
      'set laststatus=0 noshowcmd nowrap scrolloff=0 timeoutlen=20000 mouse=a mousescroll=ver:1'
    )
    api.nvim_buf_set_lines(0, 0, -1, false, vim.tbl_map(tostring, vim.fn.range(1, 80)))
    expect_view(0, 0)
  end

  before_each(setup)

  it('updates the viewport before waiting for more command input', function()
    command('nnoremap k<F6> <Nop>')
    for i, keys in ipairs({
      { 'k', '<F6>' },
      { '2', '<Esc>' },
      { 'f', '<Esc>' },
      { ':', '<Esc>' },
    }) do
      if i > 1 then
        command('normal! gg0zt')
        expect_view(0, 0)
      end
      feed(down .. keys[1])
      -- Observe only UI notifications while the command is incomplete: an RPC
      -- query could service a pending refresh and hide the missing frame.
      expect_view(5, 9)
      feed(keys[2] .. '<Esc>')
    end
  end)

  it('refreshes before Insert and Visual mode entry callbacks', function()
    exec_lua([[
      _G.last_line = 1
      _G.seen = {}
      vim.api.nvim_create_autocmd('CursorMoved', {
        callback = function() last_line = vim.fn.line('.') end,
      })
      local function observe(name)
        table.insert(seen, { name, vim.fn.line('.'), last_line })
      end
      vim.api.nvim_create_autocmd('InsertEnter', {
        callback = function() observe('insert') end,
      })
      vim.api.nvim_create_autocmd('ModeChanged', {
        pattern = 'n:v',
        callback = function() observe('visual') end,
      })
    ]])
    feed(down .. 'i<Esc>' .. down .. 'v<Esc>')
    eq({ { 'insert', 10, 10 }, { 'visual', 19, 19 } }, exec_lua('return seen'))
  end)

  it('rechecks mappings and inserted input after a refresh callback', function()
    for i, keys in ipairs({ { 'k', 'k' }, { string.char(5), '<C-E>' } }) do
      if i > 1 then
        setup()
      end
      exec_lua(
        [[
        local old_key, new_key = ...
        _G.seen = {}
        vim.keymap.set('n', old_key, function() table.insert(seen, 'old') end)
        vim.keymap.set('n', '<F6>', function() table.insert(seen, 'inserted') end)
        vim.api.nvim_create_autocmd('CursorMoved', {
          callback = function()
            if vim.fn.line('.') == 10 then
              vim.keymap.set('n', new_key, function() table.insert(seen, 'new') end)
              vim.api.nvim_feedkeys(vim.keycode('<F6>'), 'i', false)
              return true
            end
          end,
        })
      ]],
        unpack(keys)
      )
      feed(down .. keys[2])
      eq({ 'inserted', 'new' }, exec_lua('return seen'))
      eq('', n.eval('v:errmsg'))
    end
  end)

  it('refreshes before waiting for the rest of a logical key', function()
    local wheel = vim.keycode('<ScrollWheelDown>')
    -- This prefix cannot be mistaken for a partial mapping. Keep the final
    -- byte separate to exercise a wait inside special-key decoding.
    api.nvim_feedkeys(down .. wheel:sub(1, 2), 't', false)
    expect_view(5, 9)
    feed(wheel:sub(3))
    expect_view(6, 9)
  end)
end)
