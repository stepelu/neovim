-- Normal mode tests.

local t = require('test.testutil')
local n = require('test.functional.testnvim')()
local Screen = require('test.functional.ui.screen')

local describe, it, before_each = t.describe, t.it, t.before_each
local clear = n.clear
local feed = n.feed
local fn = n.fn
local command = n.command
local eq = t.eq
local api = n.api

describe('Normal mode', function()
  before_each(clear)

  it('setting &winhighlight or &winblend does not change curswant #27470', function()
    fn.setline(1, { 'long long lone line', 'short line' })
    feed('ggfi')
    local pos = fn.getcurpos()
    feed('j')
    command('setlocal winblend=10 winhighlight=Visual:Search')
    feed('k')
    eq(pos, fn.getcurpos())
  end)

  it('&showcmd does not crash with :startinsert #28419', function()
    local screen = Screen.new(60, 17)
    fn.jobstart({ n.nvim_prog, '--clean', '--cmd', 'startinsert' }, {
      term = true,
      env = { VIMRUNTIME = os.getenv('VIMRUNTIME') },
    })
    screen:expect({
      grid = [[
        ^                                                            |
        ~                                                           |*13
        [No Name]                                 0,1            All|
        -- INSERT --                                                |
                                                                    |
      ]],
      attr_ids = {},
    })
  end)

  it('replacing with ZWJ emoji sequences', function()
    local screen = Screen.new(30, 8)
    api.nvim_buf_set_lines(0, 0, -1, true, { 'abcdefg' })
    feed('05r🧑‍🌾') -- ZWJ
    screen:expect([[
      🧑‍🌾🧑‍🌾🧑‍🌾🧑‍🌾^🧑‍🌾fg                  |
      {1:~                             }|*6
                                    |
    ]])

    feed('2r🏳️‍⚧️') -- ZWJ and variant selectors
    screen:expect([[
      🧑‍🌾🧑‍🌾🧑‍🌾🧑‍🌾🏳️‍⚧️^🏳️‍⚧️g                 |
      {1:~                             }|*6
                                    |
    ]])
  end)

  it('"gk" does not crash with signcolumn=yes in narrow window #31274', function()
    feed('o<Esc>')
    command('1vsplit | setlocal signcolumn=yes')
    feed('gk')
    n.assert_alive()
  end)
end)

describe('Normal mode refresh batching', function()
  before_each(clear)

  --- Runs `keys` `count` times and returns the resulting cursor and viewport of every window.
  --- With `queued`, all keys are sent at once; otherwise each one is processed on its own.
  local function run(setup, keys, count, queued)
    clear()
    Screen.new(45, 12)
    command(setup)
    if queued then
      feed(table.concat(keys):rep(count))
    else
      for _ = 1, count do
        for _, key in ipairs(keys) do
          feed(key)
          n.poke_eventloop()
        end
      end
    end
    return n.exec_lua(function()
      return vim.tbl_map(function(win)
        local info = vim.fn.getwininfo(win)[1]
        local view = vim.api.nvim_win_call(win, vim.fn.winsaveview)
        return { vim.api.nvim_win_get_cursor(win), info.topline, info.botline, view }
      end, vim.api.nvim_tabpage_list_wins(0))
    end)
  end

  local lines = 'call setline(1, range(1, 400))'
  local wrapped = 'call setline(1, map(range(1, 400), {_, v -> repeat(v . " padding ", 9)}))'

  local function map_j_after_cursor_moves()
    n.exec_lua(function()
      _G.mapping_ran = false
      vim.api.nvim_create_autocmd('CursorMoved', {
        once = true,
        callback = function()
          vim.keymap.set('n', 'j', function()
            _G.mapping_ran = true
          end)
        end,
      })
    end)
  end

  -- Postponing the refresh must not change where the cursor and the viewports end up.
  for _, case in ipairs({
    { 'j', 'set nowrap scrolloff=0 | ' .. lines, { 'j' }, 40 },
    { 'j with scrolloff', 'set nowrap scrolloff=3 | ' .. lines, { 'j' }, 40 },
    { 'j with scrolljump', 'set nowrap scrolloff=2 scrolljump=5 | ' .. lines, { 'j' }, 40 },
    { 'k', 'set nowrap scrolloff=2 | ' .. lines .. ' | normal! G', { 'k' }, 40 },
    { 'CTRL-E', 'set nowrap scrolloff=0 | ' .. lines, { '<C-E>' }, 40 },
    { 'CTRL-Y', 'set nowrap | ' .. lines .. ' | normal! G', { '<C-Y>' }, 40 },
    { 'CTRL-D', 'set nowrap | ' .. lines, { '<C-D>' }, 12 },
    { 'CTRL-F', 'set nowrap | ' .. lines, { '<C-F>' }, 12 },
    { 'j with wrap', 'set wrap scrolloff=2 | ' .. wrapped, { 'j' }, 30 },
    {
      'CTRL-E with smoothscroll',
      'set wrap smoothscroll scrolloff=0 | ' .. wrapped,
      { '<C-E>' },
      30,
    },
    {
      'l with sidescroll',
      'set nowrap sidescroll=1 | call setline(1, repeat("x ", 300))',
      { 'l' },
      80,
    },
    -- The counts of the folded cases matter: they end the run where an approximated
    -- w_botline and an exact one disagree, which is what a postponed draw has to get right.
    {
      'j over folds',
      'set nowrap scrolloff=0 foldmethod=manual | ' .. lines .. ' | 10,20fold | 30,60fold',
      { 'j' },
      31,
    },
    { 'j in splits', 'set nowrap scrolloff=1 | ' .. lines .. ' | vsplit | split', { 'j' }, 40 },
    {
      'j with cursorbind',
      'set nowrap scrolloff=0 | '
        .. lines
        .. ' | setlocal cursorbind | vsplit | setlocal cursorbind',
      { 'j' },
      40,
    },
    {
      -- The fold is in the bound window only, so the window that has to stay exact is not
      -- the one the motions run in.  Getting this wrong scrolls its cursor off screen.
      'j with cursorbind over a fold',
      'set nowrap scrolloff=0 foldmethod=manual | '
        .. lines
        .. ' | vsplit | 10,20fold | setlocal cursorbind | wincmd l | setlocal cursorbind'
        .. ' | normal! gg',
      { 'j' },
      36,
    },
    {
      'CTRL-E with scrollbind',
      'set nowrap scrolloff=0 | '
        .. lines
        .. ' | setlocal scrollbind | vsplit | setlocal scrollbind',
      { '<C-E>' },
      30,
    },
    {
      'mixed motions',
      'set nowrap scrolloff=1 | ' .. lines,
      { 'j', 'j', '<C-E>', 'k', '<C-D>' },
      8,
    },
    { 'edits', 'set nowrap scrolloff=0 | ' .. lines, { 'dd', 'j', 'x' }, 20 },
  }) do
    local name, setup, keys, count = case[1], case[2], case[3], case[4]
    it('does not change the result of ' .. name, function()
      eq(run(setup, keys, count, false), run(setup, keys, count, true))
    end)
  end

  -- The cases above compare a queued run against the same keys processed one at a time.  This
  -- one pins the absolute geometry as well, so that a fault common to both runs still shows.
  it('keeps viewports valid across folds during queued navigation', function()
    Screen.new(40, 10)
    command('set nowrap laststatus=0 scrolloff=0 foldmethod=manual')
    fn.setline(1, fn.range(1, 80))
    command('10,20fold')
    command('normal! gg0zt')
    feed(('j'):rep(31))
    eq({ 42, 34 }, { fn.line('.'), fn.line('w0') })

    command('normal! gg0zt')
    command('setlocal cursorbind')
    local other = api.nvim_get_current_win()
    command('vsplit')
    command('normal! zE')
    feed(('j'):rep(31))
    eq({ 32, 24 }, { fn.line('.'), fn.line('w0') })
    eq({ 32, 24 }, { api.nvim_win_get_cursor(other)[1], fn.getwininfo(other)[1].topline })
  end)

  it('reports the accumulated movement to CursorMoved and WinScrolled', function()
    Screen.new(45, 12)
    command('set nowrap scrolloff=0')
    command(lines)
    n.exec_lua(function()
      _G.moves, _G.scrolls = {}, {}
      vim.api.nvim_create_autocmd('CursorMoved', {
        callback = function()
          table.insert(_G.moves, vim.api.nvim_win_get_cursor(0)[1])
        end,
      })
      vim.api.nvim_create_autocmd('WinScrolled', {
        callback = function()
          table.insert(_G.scrolls, vim.v.event.all.topline)
        end,
      })
    end)

    feed(('j'):rep(30))
    local moves = n.exec_lua('return _G.moves')
    local scrolls = n.exec_lua('return _G.scrolls')
    -- Fewer notifications than commands, but the last one has the final position and the
    -- reported scrolls add up to the movement that actually happened.
    eq(31, fn.line('.'))
    eq(31, moves[#moves])
    eq(true, #moves < 30)
    eq(
      fn.line('w0') - 1,
      vim.iter(scrolls):fold(0, function(a, b)
        return a + b
      end)
    )
  end)

  it('notifies once per command without queued input', function()
    Screen.new(45, 12)
    command(lines)
    n.exec_lua(function()
      _G.moves = 0
      vim.api.nvim_create_autocmd('CursorMoved', {
        callback = function()
          _G.moves = _G.moves + 1
        end,
      })
    end)
    for _ = 1, 10 do
      feed('j')
      n.poke_eventloop()
    end
    eq(10, n.exec_lua('return _G.moves'))
  end)

  it('classifies the command after applying langmap', function()
    Screen.new(45, 12)
    fn.setline(1, 'abcd')
    command('set langmap=jx')
    n.exec_lua(function()
      _G.changes = 0
      vim.api.nvim_create_autocmd('TextChanged', {
        callback = function()
          _G.changes = _G.changes + 1
        end,
      })
    end)
    -- Let the setline() above be reported, so only the typed commands are counted.
    n.poke_eventloop()
    n.exec_lua('_G.changes = 0')

    -- Both typed "j" commands execute "x".  Edits are not navigation and must not be batched.
    feed('jj')
    eq('cd', fn.getline(1))
    eq(2, n.exec_lua('return _G.changes'))
  end)

  it('does not batch a command that leaves Visual or Select mode', function()
    Screen.new(45, 12)
    command('set keymodel=stopsel')
    fn.setline(1, fn.range(1, 20))

    for _, start in ipairs({ 'v', 'gh' }) do
      command('normal! gg')
      map_j_after_cursor_moves()

      -- <Down> stops Visual/Select mode before moving.  Its CursorMoved observer must run
      -- before the following Normal-mode "j", so that a mapping installed by the observer
      -- applies to it.
      feed(start .. '<Down>j')
      eq(true, n.exec_lua('return _G.mapping_ran'))
      n.exec_lua("vim.keymap.del('n', 'j')")
    end
  end)

  it('does not batch a motion that finishes an operator', function()
    Screen.new(45, 12)
    fn.setline(1, fn.range(1, 20))
    command('normal! gg')
    n.exec_lua(function()
      _G.move_operator = function()
        vim.api.nvim_win_set_cursor(0, { 5, 0 })
      end
      vim.go.operatorfunc = 'v:lua._G.move_operator'
    end)
    map_j_after_cursor_moves()

    -- The first "j" is the motion for g@, not standalone navigation.  The custom operator
    -- moves the cursor, whose observer must install the mapping before the following "j".
    feed('g@jj')
    eq(true, n.exec_lua('return _G.mapping_ran'))
  end)

  it('publishes observers before evaluating a mapping', function()
    Screen.new(45, 12)
    command(lines)
    n.exec_lua(function()
      _G.last_move, _G.map_saw = 1, 0
      vim.api.nvim_create_autocmd('CursorMoved', {
        callback = function()
          _G.last_move = vim.api.nvim_win_get_cursor(0)[1]
        end,
      })
      vim.keymap.set('n', 'X', function()
        _G.map_saw = _G.last_move
        return '<Ignore>'
      end, { expr = true })
    end)

    feed('jX')
    eq(2, n.exec_lua('return _G.map_saw'))
  end)

  it('lets observers change mappings before the next key is read', function()
    Screen.new(45, 12)
    fn.setline(1, { 'abc', 'def' })
    n.exec_lua(function()
      _G.mapping_ran = false
      vim.keymap.set('n', 'x', function()
        _G.mapping_ran = true
      end)
      vim.api.nvim_create_autocmd('CursorMoved', {
        once = true,
        callback = function()
          vim.keymap.del('n', 'x')
        end,
      })
    end)

    feed('jx')
    eq(false, n.exec_lua('return _G.mapping_ran'))
    eq('ef', fn.getline(2))
  end)

  it('lets observers consume queued input', function()
    Screen.new(45, 12)
    command(lines)
    n.exec_lua(function()
      _G.consumed, _G.mapping_ran = '', false
      vim.keymap.set('n', 'X', function()
        _G.mapping_ran = true
      end)
      vim.api.nvim_create_autocmd('CursorMoved', {
        once = true,
        callback = function()
          _G.consumed = vim.fn.getcharstr(0)
        end,
      })
    end)

    feed('jX')
    eq('X', n.exec_lua('return _G.consumed'))
    eq(false, n.exec_lua('return _G.mapping_ran'))
  end)

  -- The refresh has to be published before the next key is taken out of the typeahead.
  -- Publishing after would let observers act on input that Nvim has already committed to.
  it('publishes observers before the next key is consumed', function()
    Screen.new(40, 8)
    api.nvim_buf_set_lines(0, 0, -1, false, { '032 alpha', '032 alpha' })
    n.exec_lua(function()
      vim.api.nvim_create_autocmd('CursorMoved', {
        once = true,
        callback = function()
          vim.api.nvim_feedkeys('x', 'i', false) -- prepend to the typeahead
        end,
      })
    end)
    command('normal! gg')
    -- "x" is fed by the observer, so it has to run as a command before the queued "i", not as
    -- inserted text after it.
    feed('jiQ<Esc>')
    eq('Q32 alpha', fn.getline(2))
  end)

  it('does not let observer input corrupt a queued <Cmd> command', function()
    Screen.new(40, 8)
    api.nvim_buf_set_lines(0, 0, -1, false, { '032 alpha', '032 alpha' })
    n.exec_lua(function()
      vim.g.command_ran = false
      vim.keymap.set('n', 'Z', '<Cmd>let g:command_ran = v:true<CR>')
      vim.api.nvim_create_autocmd('CursorMoved', {
        once = true,
        callback = function()
          vim.api.nvim_feedkeys('x', 'i', false) -- prepend to the typeahead
        end,
      })
    end)
    command('normal! gg')

    feed('jZ')
    eq('32 alpha', fn.getline(2))
    eq(true, api.nvim_get_var('command_ran'))
  end)

  it('publishes observers before a key that only a mapping would resolve', function()
    Screen.new(40, 8)
    fn.setline(1, fn.range(1, 50))
    n.exec_lua(function()
      _G.mapped = false
      vim.api.nvim_create_autocmd('CursorMoved', {
        once = true,
        callback = function()
          vim.keymap.set('n', 'Z', function()
            _G.mapped = true
          end)
        end,
      })
    end)
    command('normal! gg')
    -- Without publishing first, "Z" reaches the mapping engine before the mapping exists and
    -- is then taken literally, which waits forever for the second key of "ZZ"/"ZQ".
    feed('jZ')
    eq(true, n.exec_lua('return _G.mapped'))
  end)

  it('publishes before a queued key blocks in the mapping engine', function()
    Screen.new(40, 8)
    command('set timeoutlen=30000 nowrap scrolloff=0')
    fn.setline(1, fn.range(1, 400))
    command('nnoremap jq <Nop>')
    command('normal! gg')
    local channel = api.nvim_get_api_info()[1]
    n.exec_lua(function(chan)
      vim.api.nvim_create_autocmd('CursorMoved', {
        callback = function()
          vim.rpcnotify(chan, 'moved', vim.api.nvim_win_get_cursor(0)[1])
        end,
      })
    end, channel)

    -- Every "j" may still start the "jq" mapping, so the run cannot be batched at all: the
    -- last one blocks for 'timeoutlen' and must not strand the movement before it.
    api.nvim_input(('j'):rep(31))
    -- Reading this passively is what makes the test meaningful: a request would itself wait
    -- behind the pending mapping, and so would be answered only after 'timeoutlen'.  The
    -- timeout is far longer than this wait, so arriving at all is the assertion.
    local line = 0
    while line < 31 do
      local message = assert(n.next_msg(5000), 'CursorMoved was not published before the wait')
      if message[2] == 'moved' then
        line = message[3][1]
      end
    end

    -- Resolve the mapping rather than waiting out 'timeoutlen'.  <Esc> cannot continue "jq",
    -- so the pending "j" runs at once; if 'timeoutlen' won the race it already did, and <Esc>
    -- is a no-op either way.  A literal "q" would instead start recording and block.
    api.nvim_input('<Esc>')
    eq(32, fn.line('.'))
  end)

  it('publishes before an incomplete UTF-8 key blocks in vgetc()', function()
    Screen.new(40, 8)
    fn.setline(1, fn.range(1, 50))
    local channel = api.nvim_get_api_info()[1]
    n.exec_lua(function(chan)
      vim.api.nvim_create_autocmd('CursorMoved', {
        once = true,
        callback = function()
          vim.rpcnotify(chan, 'movement_published', vim.api.nvim_win_get_cursor(0)[1])
        end,
      })
    end, channel)
    command('normal! gg')

    -- 0xc3 starts a two-byte UTF-8 character. vgetc() must wait for its continuation, but the
    -- movement before it has to be published first.
    api.nvim_input('j' .. string.char(0xc3))
    local message
    repeat
      message = assert(n.next_msg(), 'CursorMoved was not published before vgetc() blocked')
    until message[1] == 'notification' and message[2] == 'movement_published'
    eq(2, message[3][1])

    -- Complete the key so the test does not leave Nvim blocked.
    api.nvim_input(string.char(0xa9))
  end)

  it('does not recursively publish from a CursorMoved callback', function()
    Screen.new(45, 12)
    command(lines)
    n.exec_lua(function()
      _G.moves = 0
      vim.api.nvim_create_autocmd('CursorMoved', {
        callback = function()
          _G.moves = _G.moves + 1
          if _G.moves == 1 then
            vim.cmd.normal({ 'j', bang = true })
          end
        end,
      })
    end)

    feed('jj')
    eq(4, fn.line('.'))
    eq(1, n.exec_lua('return _G.moves'))
  end)

  it('draws the postponed state before a command that is not a motion', function()
    local screen = Screen.new(20, 4)
    fn.setline(1, { 'one', 'two' })
    feed('gg')
    screen:expect({ any = '%^one' })
    vim.uv.sleep(20)
    -- "j" postpones, ":" cannot: the result of "j" must be on screen under the command line.
    feed('j:')
    screen:expect([[
      one                 |
      two                 |
      {1:~                   }|
      :^                   |
    ]])
  end)

  it('does not flush intermediate frames for a short burst after idle', function()
    local screen = Screen.new(40, 10)
    fn.setline(1, fn.range(1, 80))
    command('normal! gg')
    screen:expect({ any = '%^1 +' })
    -- Sleep in the test runner so the editor remains idle.
    vim.uv.sleep(20)
    feed('jjgg')
    screen:expect_unchanged()
  end)

  for _, input in ipairs({ '<ScrollWheelDown>', '<C-E>' }) do
    it('flushes intermediate frames while ' .. input .. ' remains queued', function()
      local screen = Screen.new(40, 10)
      command('set mouse=a mousescroll=ver:1,hor:1 nowrap scrolloff=0')
      fn.setline(1, fn.range(1, 200))
      command('normal! gg')
      n.exec_lua(function(next_key)
        local count = 0
        vim.on_key(function(key)
          if key == vim.keycode(next_key) then
            count = count + 1
            if count == 8 or count == 24 then
              -- Cross the redraw budget without yielding or inserting another key.
              vim.uv.sleep(20)
            end
          end
        end)
      end, input)
      feed((input .. (input == '<ScrollWheelDown>' and '<0,0>' or '')):rep(32))
      local seen = {}
      screen:expect(function()
        local view = screen.win_viewport[2]
        if view then
          seen[view.topline] = true
        end
        eq(true, seen[8])
        eq(true, seen[24])
        eq(32, view.topline)
      end)
    end)
  end

  it('draws before waiting for the rest of a mapping', function()
    local screen = Screen.new(20, 4)
    command('set timeoutlen=10000')
    command('nnoremap jk <Nop>')
    command('set scrolloff=0')
    fn.setline(1, { 'one', 'two', 'three', 'four' })
    -- "j" may still start the "jk" mapping.  Waiting for the rest of it must not leave the
    -- scroll that CTRL-E postponed undrawn for 'timeoutlen'.
    feed('gg<C-E>j')
    screen:expect([[
      ^two                 |
      three               |
      four                |
                          |
    ]])
  end)

  it('draws before the command line takes over the screen', function()
    local screen = Screen.new(20, 4)
    fn.setline(1, 'one')
    feed('ggx:')
    screen:expect([[
      ne                  |
      {1:~                   }|*2
      :^                   |
    ]])
  end)

  it('draws before a prompt takes over the screen', function()
    local screen = Screen.new(20, 6)
    fn.setline(1, 'one')
    feed('ggx:echon "a\\nb"<CR>')
    screen:expect([[
      ne                  |
      {3:                    }|
      a                   |
      b                   |
      {6:Press ENTER or type }|
      {6:command to continue}^ |
    ]])
  end)
end)
