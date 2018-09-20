---
title: "Favorite Vim Settings"
date: 2018-09-20T21:49:45+02:00
draft: false
tags: [vim]
---

## Preface

Collection of my favorite vim settings taken from my
[vimrc](https://github.com/mandreyel/dotfiles/blob/master/vim/.vimrc).

## Line numbers

Set both `number` and `relativenumber` to show the line number under the cursor
as well as the distance of surrounding lines. However, this is only useful while
in command mode, so an `autocommand` can be used to switch to only display
absolute line numbers when entering insert mode or when switching to another
buffer:

```vim
set number
set relativenumber

" Show relative line numbers when in command mode or switching to another
" buffer, and show absolute line numbers when in insert mode.
augroup NumberToggle
  autocmd!
  autocmd BufEnter,FocusGained,InsertLeave * set relativenumber
  autocmd BufLeave,FocusLost,InsertEnter   * set norelativenumber
augroup END
```

## Preemptive scrolling

Set `scrolloff` to some number to leave that many lines above or under the
cursor when reaching the top or bottom of the window. However, this breaks
`Shift+L` and `Shift+H` when you want to navigate to the top or bottom of the
window. We can remap these to travel the rest of the `scrolloff` value.

```vim
" Always leave 5 lines above/below the cursor when nearing the top/bottom of the
" window.
set scrolloff=5
" Due to scrollof, Shift+{H,L} no longer go to the top/bottom of the visible
" window, so we need to skip the rest of the way there with the movement
" commands.
nnoremap <S-h> <S-h>5k
nnoremap <S-l> <S-l>5j
```

## Editing & sourcing vimrc

If you customize vim all the time, then it is extremely useful to quickly hop
into your vimrc and then source it, all without every exiting vim--which is
very nearly impossible, from what I hear!

```vim
" Shortcuts to quickly edit and source .vimrc.
nnoremap <leader>ve :e $MYVIMRC<CR>
nnoremap <leader>vs :source $MYVIMRC<CR>
```

## Save read-only files

You should probably use `sudoedit` but this can come in handy when you've
forgotten to use that:

```vim
cmap w!! w !sudo tee % >/dev/null
```

## Visual selection enhancements

Visually select the text that was last edited/pasted:
```vim
 noremap gV `[v`]
```

Reselect visual block after indentation:
```vim
vnoremap < <gv
vnoremap > >gv
```

## More intuitive searching

Highlight search matches:
```vim
set hlsearch
```

Move cursor to the closest match:
```vim
set incsearch
```

Ignore cases, *but* only when the cases are not uniform. That is, make searching
case-sensitive when there are upper and lower case letters.
```vim
set ignorecase
set smartcase
```

Starting the search backwards or forwards switches up the role of the `n` and
`N` keys. This is rather confusing, so let's make pressing `n` always go to the next
search match and pressing `N` always go to the previous match. This also centers
the screen on the current match under the cursor.
```vim
nnoremap <expr> n 'Nn'[v:searchforward] . 'zz'
nnoremap <expr> N 'nN'[v:searchforward] . 'zz'
```

## More intuitive movements

When you have line wrapping on, navigating them is not exactly intuitive
(e.g. pressing the up and down keys traverse to the next logical line, not the next
line visible on screen). This is easy to remedy:
```vim
" Navigate wrapped lines as though they were normal lines with line breaks.
nnoremap j gj
nnoremap k gk
nnoremap $ g$
nnoremap 0 g0
```

`C` and `D` change or delete the rest of the line starting at cursor, however
their "opposite" command, `Y` (copying/yanking), does not do anything, which is
rather counter-intuitive. Let's make it behave like the other capitalized
movement commands:
```vim
nnoremap Y y$
```

## Moving lines up and down

I really don't like IDEs, but they have one feature I missed in vim: moving
lines up and down, without the ritual of deleting (`dd`) and pasting them above
or below the cursor (`<s-p>` or `p`). Though admittedly this is only a gain if
you want to move a line a few lines at most, as otherwise deleting it, using a
more efficient movement command and pasting it elsewhere is more efficient.
```vim
nnoremap <silent> <C-k> :move-2<CR>
xnoremap <silent> <C-k> :move-2<CR>gv
nnoremap <silent> <C-j> :move+<CR>
xnoremap <silent> <C-j> :move'>+<CR>gv
```

## Better formatting

`formatoptions` is worth researching, it has a lot of interesting options. My
favorites:

Remove the comment leader character when joining lines with `Shift+j`:
```vim
set formatoptions+=j
```

Automatically insert the comment leader when hitting enter:
```vim
set formatoptions+=r
```

Automatically insert the comment leader when entering insert mode with `o` or
`Shift+o`:
```vim
set formatoptions+=o
```

Allow formatting comments with `gq`:
```vim
set formatoptions+=q
```
