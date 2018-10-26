" swap object - Managing a whole action.

let s:const = swap#constant#import(s:, ['TYPESTR', 'TYPENUM', 'NULLREGION'])
let s:lib = swap#lib#import()

let s:TRUE = 1
let s:FALSE = 0
let s:TYPESTR = s:const.TYPESTR
let s:TYPENUM = s:const.TYPENUM
let s:TYPEFUNC = s:const.TYPEFUNC
let s:NULLREGION = s:const.NULLREGION
let s:GUI_RUNNING = has('gui_running')


function! swap#swap#new(mode, input_list) abort "{{{
  let swap = deepcopy(s:swap_prototype)
  let swap.mode = a:mode
  let swap.input_list = a:input_list
  let swap.rules = s:get_rules(a:mode)
  return swap
endfunction "}}}


let s:swap_prototype = {
      \   'dotrepeat': s:FALSE,
      \   'mode': '',
      \   'rules': [],
      \   'input_list': [],
      \ }


function! s:swap_prototype.around_cursor() abort "{{{
  let options = s:displace_options()
  try
    call self._around_cursor()
  finally
    call s:restore_options(options)
  endtry
endfunction "}}}


function! s:swap_prototype._around_cursor() abort "{{{
  let rules = deepcopy(self.rules)
  let [buffer, rule] = s:search(rules, 'char')
  if self.dotrepeat
    call self._swap_sequential(buffer)
  else
    if empty(rule)
      return
    endif
    let self.rules = [rule.initialize()]
    if self.input_list != []
      call self._swap_sequential(buffer)
    else
      let self.input_list = self._swap_interactive(buffer)
    endif
  endif
endfunction "}}}


function! s:swap_prototype.region(start, end, type) abort "{{{
  let options = s:displace_options()
  try
    call self._region(a:start, a:end, a:type)
  finally
    call s:restore_options(options)
  endtry
endfunction "}}}


function! s:swap_prototype._region(start, end, type) abort "{{{
  let region = s:get_region(a:start, a:end, a:type)
  if region is# s:NULLREGION
    return
  endif
  let rules = deepcopy(self.rules)
  let [buffer, rule] = s:match(region, rules)
  if self.dotrepeat
    call self._swap_sequential(buffer)
  else
    let self.rules = [rule]
    if self.input_list != []
      call self._swap_sequential(buffer)
    else
      let self.input_list = self._swap_interactive(buffer)
    endif
  endif
endfunction "}}}


function! s:swap_prototype.operatorfunc(type) dict abort "{{{
  if self.mode is# 'n'
    call self.around_cursor()
  elseif self.mode is# 'x'
    let start = getpos("'[")
    let end = getpos("']")
    call self.region(start, end, a:type)
  endif
  let self.dotrepeat = s:TRUE
endfunction "}}}


function! s:swap_prototype._swap_interactive(buffer) dict abort "{{{
  if a:buffer == {}
    return []
  endif

  let input_list = []
  let buffer = a:buffer
  let undojoin = s:FALSE
  let interface = swap#interface#new()
  while s:TRUE
    let input = interface.query(buffer)
    if input == [] | break | endif
    let [buffer, undojoin] = self._swap_once(buffer, input, undojoin)
    call add(input_list, input)
  endwhile
  return input_list
endfunction "}}}


function! s:swap_prototype._swap_sequential(buffer) dict abort  "{{{
  if a:buffer == {}
    return
  endif

  let buffer = a:buffer
  let undojoin = s:FALSE
  for input in self.input_list
    let [buffer, undojoin] = self._swap_once(buffer, input, undojoin)
  endfor
  return self.input_list
endfunction "}}}


function! s:swap_prototype._swap_once(buffer, input, undojoin) dict abort "{{{
  if a:input == []
    return [a:buffer, a:undojoin]
  endif

  " substitute and eval symbols
  let input = map(copy(a:input), 's:eval(v:key, v:val, a:buffer)')
  if !s:is_valid_input(input, a:buffer)
    return [a:buffer, a:undojoin]
  endif

  " swap items on the buffer
  let newbuffer = s:swap(a:buffer, input)
  call s:write(newbuffer, a:undojoin)

  " update buffer information
  let newbuffer.region.head = getpos("'[")
  let newbuffer.region.tail = getpos("']")
  call newbuffer.update_items()
  call newbuffer.items[input[1] - 1].cursor()
  call newbuffer.update_sharp(getpos('.'))
  call newbuffer.update_hat()
  return [newbuffer, s:TRUE]
endfunction "}}}


" This method is mainly for textobjects
function! s:swap_prototype.search(motionwise, ...) abort "{{{
  let rules = deepcopy(self.rules)
  let textobj = get(a:000, 0, 0)
  return s:search(rules, a:motionwise, textobj)
endfunction "}}}


function! s:displace_options() abort  "{{{
  let options = {}
  let options.virtualedit = &virtualedit
  let options.whichwrap = &whichwrap
  let options.selection = &selection
  let [&virtualedit, &whichwrap, &selection] = ['onemore', 'h,l', 'inclusive']
  if s:GUI_RUNNING
    let options.cursor = &guicursor
    set guicursor+=n-o:block-NONE
  else
    let options.cursor = &t_ve
    set t_ve=
  endif
  let options.cursorline = &l:cursorline
  setlocal nocursorline
  return options
endfunction "}}}


function! s:restore_options(options) abort "{{{
  let &virtualedit = a:options.virtualedit
  let &whichwrap = a:options.whichwrap
  let &selection = a:options.selection
  if s:GUI_RUNNING
    set guicursor&
    let &guicursor = a:options.cursor
  else
    let &t_ve = a:options.cursor
  endif
  let &l:cursorline = a:options.cursorline
endfunction "}}}


function! s:get_rules(mode) abort  "{{{
  let rules = deepcopy(get(g:, 'swap#rules', g:swap#default_rules))
  call map(rules, 'extend(v:val, {"priority": 0}, "keep")')
  call s:lib.sort(reverse(rules), function('s:compare_priority'))
  call filter(rules, 's:filter_filetype(v:val) && s:filter_mode(v:val, a:mode)')
  if a:mode isnot# 'x'
    call s:remove_duplicate_rules(rules)
  endif
  return map(rules, 'swap#rule#get(v:val)')
endfunction "}}}


function! s:filter_filetype(rule) abort  "{{{
  if !has_key(a:rule, 'filetype')
    return s:TRUE
  endif
  let filetypes = split(&filetype, '\.')
  if filetypes == []
    let filter = 'v:val is# ""'
  else
    let filter = 'v:val isnot# "" && count(filetypes, v:val) > 0'
  endif
  return filter(copy(a:rule['filetype']), filter) != []
endfunction "}}}


function! s:filter_mode(rule, mode) abort  "{{{
  if !has_key(a:rule, 'mode')
    return s:TRUE
  endif
  return stridx(a:rule.mode, a:mode) > -1
endfunction "}}}


function! s:remove_duplicate_rules(rules) abort "{{{
  let i = 0
  while i < len(a:rules)
    let representative = a:rules[i]
    let j = i + 1
    while j < len(a:rules)
      let target = a:rules[j]
      let duplicate_body = 0
      let duplicate_surrounds = 0
      if (has_key(representative, 'body') && has_key(target, 'body') && representative.body == target.body)
            \ || (!has_key(representative, 'body') && !has_key(target, 'body'))
        let duplicate_body = 1
      endif
      if (has_key(representative, 'surrounds') && has_key(target, 'surrounds') && representative.surrounds[0:1] == target.surrounds[0:1] && get(representative, 2, 1) == get(target, 2, 1))
            \ || (!has_key(representative, 'surrounds') && !has_key(target, 'surrounds'))
        let duplicate_surrounds = 1
      endif
      if duplicate_body && duplicate_surrounds
        call remove(a:rules, j)
      else
        let j += 1
      endif
    endwhile
    let i += 1
  endwhile
endfunction "}}}


function! s:get_region(start, end, type) abort "{{{
  let region = deepcopy(s:NULLREGION)
  let region.head = a:start
  let region.tail = a:end
  let region.type = a:type
  if !s:lib.is_valid_region(region)
    return s:NULLREGION
  endif

  let region.len = s:lib.get_buf_length(region)
  return region
endfunction "}}}


function! s:get_priority_group(rules) abort "{{{
  " NOTE: This function move items in a:rules to priority_group.
  "       Thus it makes changes to a:rules also.
  let priority = get(a:rules[0], 'priority', 0)
  let priority_group = []
  while a:rules != []
    let rule = a:rules[0]
    if rule.priority != priority
      break
    endif
    call add(priority_group, remove(a:rules, 0))
  endwhile
  return priority_group
endfunction "}}}


function! s:search(rules, motionwise, ...) abort "{{{
  let view = winsaveview()
  let textobj = get(a:000, 0, 0)
  let curpos = getpos('.')
  let buffer = {}
  let virtualedit = &virtualedit
  let &virtualedit = 'onemore'
  try
    while a:rules != []
      let priority_group = s:get_priority_group(a:rules)
      let [buffer, rule] = s:search_by_group(priority_group, curpos,
                                           \ a:motionwise, textobj)
      if buffer != {}
        break
      endif
    endwhile
  finally
    let &virtualedit = virtualedit
  endtry
  call winrestview(view)
  return buffer != {} ? [buffer, rule] : [{}, {}]
endfunction "}}}


function! s:search_by_group(priority_group, curpos, motionwise, ...) abort "{{{
  let textobj = get(a:000, 0, 0)
  while a:priority_group != []
    for rule in a:priority_group
      call rule.search(a:curpos, a:motionwise)
    endfor
    call filter(a:priority_group, 's:lib.is_valid_region(v:val.region)')
    call s:lib.sort(a:priority_group, function('s:compare_len'))

    for rule in a:priority_group
      let region = rule.region
      let buffer = swap#parser#parse(region, rule, a:curpos)
      if buffer.swappable() || (textobj && buffer.selectable())
        return [buffer, rule]
      endif
    endfor
  endwhile
  return [{}, {}]
endfunction "}}}


function! s:match(region, rules) abort  "{{{
  if a:region == s:NULLREGION
    return [{}, {}]
  endif

  let view = winsaveview()
  let curpos = getpos('.')
  let buffer = {}
  while a:rules != []
    let priority_group = s:get_priority_group(a:rules)
    let [buffer, rule] = s:match_group(a:region, priority_group, curpos)
    if buffer != {}
      break
    endif
  endwhile
  call winrestview(view)
  return buffer != {} ? [buffer, rule] : [{}, {}]
endfunction "}}}


function! s:match_group(region, priority_group, curpos) abort "{{{
  for rule in a:priority_group
    if rule.match(a:region)
      let buffer = swap#parser#parse(a:region, rule, a:curpos)
      if buffer.swappable()
        return [buffer, rule]
      endif
    endif
  endfor
  return [{}, {}]
endfunction "}}}


function! s:compare_priority(r1, r2) abort "{{{
  let priority_r1 = get(a:r1, 'priority', 0)
  let priority_r2 = get(a:r2, 'priority', 0)
  if priority_r1 > priority_r2
    return -1
  elseif priority_r1 < priority_r2
    return 1
  else
    return 0
  endif
endfunction "}}}


function! s:compare_len(r1, r2) abort "{{{
  return a:r1.region.len - a:r2.region.len
endfunction "}}}


function! s:substitute_symbol(str, symbol, symbol_idx) abort "{{{
  let symbol = s:lib.escape(a:symbol)
  return substitute(a:str, symbol, a:symbol_idx, '')
endfunction "}}}


let s:sortfunc = function('sort')

function! s:eval(i, v, buffer) abort "{{{
  if type(a:v) isnot# s:TYPESTR
    return a:v
  endif
  if a:i == 0 && a:v is# 'sort'
    return s:sortfunc
  endif

  let str = a:v
  for [symbol, symbolidx] in items(a:buffer.mark)
    if stridx(str, symbol) > -1
      let str = s:substitute_symbol(str, symbol, symbolidx)
    endif
  endfor
  sandbox let v = eval(str)
  return v
endfunction "}}}


function! s:is_valid_input(input, buffer) abort "{{{
  let type_input0 = type(a:input[0])
  if type_input0 is# s:TYPENUM
    let type_input1 = type(a:input[1])
    if type_input1 isnot# s:TYPENUM
      return s:FALSE
    endif
    let n = len(a:buffer.items)
    if a:input[0] < 1 || a:input[0] > n
      return s:FALSE
    endif
    if a:input[1] < 1 || a:input[1] > n
      return s:FALSE
    endif
  elseif type_input0 is# s:TYPEFUNC
    " No limitation for a:input[1]
  else
    return s:FALSE
  endif
  return s:TRUE
endfunction "}}}


function! s:new_empty_buffer(buffer) abort "{{{
  let newbuffer = deepcopy(a:buffer)
  call filter(newbuffer.all, 0)
  call filter(newbuffer.items, 0)
  return newbuffer
endfunction "}}}


function! s:swap(buffer, input) abort "{{{
  if type(a:input[0]) is# s:TYPEFUNC
    return s:swap_by_func(a:buffer, a:input)
  endif
  return s:swap_2_items(a:buffer, a:input)
endfunction "}}}


function! s:swap_2_items(buffer, input) abort "{{{
  let itemindexes = range(len(a:buffer.items))
  let idx1 = a:input[0] - 1
  let idx2 = a:input[1] - 1
  call remove(itemindexes, idx1)
  call insert(itemindexes, idx2, idx1)
  call remove(itemindexes, idx2)
  call insert(itemindexes, idx1, idx2)

  let newbuffer = s:new_empty_buffer(a:buffer)
  for item in a:buffer.all
    if item.attr is# 'item'
      let i = remove(itemindexes, 0)
      let item = a:buffer.items[i]
      call add(newbuffer.items, item)
    endif
    call add(newbuffer.all, item)
  endfor
  return newbuffer
endfunction "}}}


let s:INVALID = 0

function! s:swap_by_func(buffer, input) abort "{{{
  let itemstr_list = map(copy(a:buffer.items), 'v:val.string')
  sandbox let sorted_list = call(a:input[0], [itemstr_list] + a:input[1:])

  let newbuffer = s:new_empty_buffer(a:buffer)
  let items = copy(a:buffer.items)
  if len(sorted_list) != len(items)
    echoerr printf('vim-swap: The swap function "%s" should not change the number of items.',
                 \ string(a:input[0]))
  endif
  for item in a:buffer.all
    if item.attr is# 'item'
      let str = remove(sorted_list, 0)
      let item = s:pickup(items, str)
      if item is# s:INVALID
        echoerr printf('vim-swap: The swap function "%s" returned an invalid list.',
                     \ string(a:input[0]))
      endif
      call add(newbuffer.items, item)
    endif
    call add(newbuffer.all, item)
  endfor
  return newbuffer
endfunction "}}}


function! s:pickup(list, str) abort "{{{
  for i in range(len(a:list))
    if a:list[i].string is# a:str
      return remove(a:list, i)
    endif
  endfor
  return s:INVALID
endfunction "}}}


function! s:string(buffer) abort "{{{
  return join(map(copy(a:buffer.all), 'v:val.string'), '')
endfunction "}}}


function! s:write(buffer, undojoin) abort "{{{
  let str = s:string(a:buffer)
  let v = s:lib.type2v(a:buffer.region.type)
  let view = winsaveview()
  let undojoin_cmd = a:undojoin ? 'undojoin | ' : ''
  let reg = ['"', getreg('"'), getregtype('"')]
  call setreg('"', str, v)
  call setpos('.', a:buffer.region.head)
  execute printf('%snoautocmd normal! "_d%s:call setpos(".", %s)%s""P:',
               \ undojoin_cmd, v, string(a:buffer.region.tail), "\<CR>")
  call call('setreg', reg)
  call winrestview(view)
endfunction "}}}


" vim:set foldmethod=marker:
" vim:set commentstring="%s:
" vim:set ts=2 sts=2 sw=2:
