#!/usr/bin/env bash
# The part of the install that is just waiting.
#
# Every other screen in this installer is measured in seconds. This one is
# measured in ten minutes, and until now it held a title, a list and a bar. The
# longest screen in the product was the least designed one, which is backwards.
#
# Three things live here, and none of them can touch the install:
#
#   the tips, read from lib/kibaos-tips, shared with the graphical front end so
#   that the two installers never tell the same person different things;
#
#   an aurora, drawn in text, which is the brand ribbon at the only fidelity a
#   virtual console has;
#
#   a snake, because ten minutes is a long time and somebody who cannot do
#   anything else should at least be able to do something.
#
# Nothing in this file reads the journal, runs a command, or has any way to
# reach the engine. The worst a bug here can do is draw badly.

# --------------------------------------------------------------------------
# The mark
# --------------------------------------------------------------------------
#
# The same A the graphical installer draws, at the only fidelity a virtual
# console has.
#
# It is a letter and it is one continuous stroke, which is the whole idea of
# the mark: the crossbar does not cross, it loops. A plain block A would have
# been easier to draw and would have been a different logo, and a text
# installer that shows a different logo to the graphical one is two products.
#
# Seven rows, because that is the smallest it can be and still keep the loop.
KIBAOS_MARK=(
'        /\'
'       /  \'
'      /    \'
'     /  __  \'
'    /  /  \  \'
'   /  (____)  \'
'  /__/      \__\'
)

#: Today, as month and day. Injectable, so the seasonal lines below can be
#: tested without waiting for December.
KIBAOS_TODAY=${KIBAOS_TODAY:-$(date +%m%d)}

# One line of sky above the mark, which is empty on all but a few days a year.
#
# The rule for these is that somebody who is not looking for them never
# notices, and somebody who happens to install KibaOS on the right day gets a
# small thing that was clearly put there on purpose. An easter egg that
# announces itself is a feature.
kibaos_mark_sky() {
  case $KIBAOS_TODAY in
    # The dark end of the year in the hemisphere most of these machines are
    # in. Sparse, because snow drawn densely in ASCII is static.
    12[2-9]*|123[01]|010[1]) printf '     .   *      .   *' ;;
    # The twenty ninth of February: a day that is not usually there, marked by
    # something crossing a sky that is not usually there either.
    0229) printf '        - - *' ;;
    *) printf '' ;;
  esac
}

# --------------------------------------------------------------------------
# Tips
# --------------------------------------------------------------------------

KIBAOS_TIPS=()
KIBAOS_TIPS_NEXT=()
KIBAOS_TIPS_RARE=()
KIBAOS_TIPS_LONG=()
KIBAOS_TIPS_LOADED=0

#: After this many seconds the long lane takes over the tip line and does not
#: give it back. Twenty minutes is well past the point where a normal install
#: has finished, so anybody still reading has started to wonder whether the
#: thing has frozen, and every other tip on the rotation is answering a
#: question they have stopped asking.
KIBAOS_TIP_LONG_AFTER=${KIBAOS_TIP_LONG_AFTER:-1200}

#: How often the rare lane comes up. One rotation in this many, on average.
KIBAOS_TIP_RARITY=${KIBAOS_TIP_RARITY:-40}

kibaos_tips_load() {
  (( ! KIBAOS_TIPS_LOADED )) || return 0
  local file=${KIBAOS_TIPS_FILE:-} candidate lane text
  if [[ -z $file ]]; then
    for candidate in /usr/local/lib/kibaos/kibaos-tips \
                     "${BASH_SOURCE[0]%/*}/kibaos-tips"; do
      [[ -r $candidate ]] || continue
      file=$candidate
      break
    done
  fi
  KIBAOS_TIPS_LOADED=1
  [[ -n $file && -r $file ]] || return 0
  while IFS=$'\t' read -r lane text; do
    [[ -n $lane && $lane != '#'* ]] || continue
    [[ -n $text ]] || continue
    case $lane in
      tip)  KIBAOS_TIPS+=("$text") ;;
      next) KIBAOS_TIPS_NEXT+=("$text") ;;
      rare) KIBAOS_TIPS_RARE+=("$text") ;;
      long) KIBAOS_TIPS_LONG+=("$text") ;;
    esac
  done <"$file"
  return 0
}

# The line for somebody who has been watching this for twenty minutes.
#
# It replaces the rotation rather than joining it. At that point the useful
# thing to say is not another fact about Btrfs, it is that this is still
# running, because the question they now have is whether it has stopped.
kibaos_tip_long() {
  local elapsed=${1:-0}
  kibaos_tips_load
  (( elapsed >= KIBAOS_TIP_LONG_AFTER )) || { printf ''; return 0; }
  (( ${#KIBAOS_TIPS_LONG[@]} > 0 )) || { printf ''; return 0; }
  printf '%s' "${KIBAOS_TIPS_LONG[0]}"
}

# The tip for a given rotation.
#
# Walking the list in order rather than picking at random, because random
# repeats and a repeat on a screen somebody is staring at reads as a screen
# that has frozen. The `next` lane is interleaved every fourth rotation, so
# what to do after the restart keeps coming back around without crowding out
# everything else.
#
# The rare lane is the exception and is genuinely random, because something
# that turns up on a fixed schedule is not a surprise the second time.
kibaos_tip_for() {
  local index=${1:-0} pool
  kibaos_tips_load
  if (( ${#KIBAOS_TIPS_RARE[@]} > 0 && KIBAOS_TIP_RARITY > 0 )) &&
     (( RANDOM % KIBAOS_TIP_RARITY == 0 )); then
    printf '%s' "${KIBAOS_TIPS_RARE[RANDOM % ${#KIBAOS_TIPS_RARE[@]}]}"
    return 0
  fi
  if (( index % 4 == 3 && ${#KIBAOS_TIPS_NEXT[@]} > 0 )); then
    printf '%s' "${KIBAOS_TIPS_NEXT[(index / 4) % ${#KIBAOS_TIPS_NEXT[@]}]}"
    return 0
  fi
  (( ${#KIBAOS_TIPS[@]} > 0 )) || { printf ''; return 0; }
  pool=$(( index - index / 4 ))
  printf '%s' "${KIBAOS_TIPS[pool % ${#KIBAOS_TIPS[@]}]}"
}

# --------------------------------------------------------------------------
# The aurora, in text
# --------------------------------------------------------------------------

#: Density ramp, sparse to solid. ASCII for the same reason the progress bar
#: is ASCII: it is one column wide in every font a virtual console might be
#: using, and a box-drawing character that falls back to a question mark is
#: worse than no picture at all.
KIBAOS_AURORA_RAMP=' .:-=+*#'

# Three rows of a slow wave, phased by `frame`.
#
# awk rather than bash arithmetic because this needs a sine and bash has no
# floating point. One process per frame at three frames a second is nothing
# next to the pacstrap running underneath it.
#
# Two waves of different wavelength and opposite drift, summed. One wave is a
# ripple; two that disagree is a thing that never quite repeats, which is what
# makes it worth looking at for ten minutes.
#: While this is above zero the ribbon swings harder and the wave is faster.
#: It is set by typing a word at the progress screen, counted down a frame at
#: a time, and it does nothing else.
KIBAOS_AURORA_BLOOM=0

# A shooting star, when there happens to be one.
#
# The aurora is a wave, and a wave is restful and completely predictable after
# about thirty seconds of watching it. This is the thing that is not: it
# crosses once, it takes about a second, and then there is not another one for
# a while.
#
# Rare on purpose. At one in fifty-five frames it turns up roughly every seven
# seconds, which over a ten minute install is often enough to be worth
# glancing up for and seldom enough that it never becomes the screen's
# heartbeat. Something that arrives on a schedule is not a surprise twice.
#: Column of the head and the row it is on. A negative column means there is
#: no star at the moment, which is nearly always.
KIBAOS_STAR_X=-1
KIBAOS_STAR_Y=0

#: One frame in this many starts one. Zero switches them off, which is what
#: the render tests and reduced motion both do.
KIBAOS_STAR_RARITY=${KIBAOS_STAR_RARITY:-55}

#: Head first, then the tail it leaves behind it.
KIBAOS_STAR_TRAIL='*--..'

kibaos_star_step() {
  local width=${1:-56} rows=${2:-3}
  if (( KIBAOS_STAR_X >= 0 )); then
    KIBAOS_STAR_X=$(( KIBAOS_STAR_X + 5 ))
    # It descends across the whole crossing rather than travelling flat. On
    # three rows that is the difference between a shooting star and an
    # underline.
    KIBAOS_STAR_Y=$(( (KIBAOS_STAR_X * rows) / (width + 8) ))
    (( KIBAOS_STAR_Y < rows )) || KIBAOS_STAR_Y=$(( rows - 1 ))
    (( KIBAOS_STAR_X <= width + 6 )) || KIBAOS_STAR_X=-1
    return 0
  fi
  (( KIBAOS_STAR_RARITY > 0 )) || return 0
  (( RANDOM % KIBAOS_STAR_RARITY == 0 )) || return 0
  KIBAOS_STAR_X=0
  KIBAOS_STAR_Y=0
  return 0
}

kibaos_aurora() {
  local frame=${1:-0} width=${2:-56} rows=${3:-3}
  local bloom=0
  (( KIBAOS_AURORA_BLOOM <= 0 )) || bloom=1
  awk -v frame="$frame" -v width="$width" -v rows="$rows" -v bloom="$bloom" \
      -v ramp="$KIBAOS_AURORA_RAMP" \
      -v star_x="$KIBAOS_STAR_X" -v star_y="$KIBAOS_STAR_Y" \
      -v trail="$KIBAOS_STAR_TRAIL" '
    BEGIN {
      steps = length(ramp)
      middle = (rows - 1) / 2
      thickness = bloom ? 2.1 : 1.35
      swing = bloom ? 1.7 : 1.0
      for (y = 0; y < rows; y++) {
        line = ""
        for (x = 0; x < width; x++) {
          # Where the ribbon is at this column. A band that moves, rather than
          # a level that fills from the bottom: filling upward reads as a
          # progress bar, and there is already a progress bar on this screen.
          centre = middle \
            + 0.85 * swing * sin(x * 0.17 + frame * 0.09 * swing) \
            + 0.45 * swing * sin(x * 0.061 - frame * 0.052 * swing)
          level = 1 - (centre > y ? centre - y : y - centre) / thickness
          if (level < 0) level = 0
          if (level > 1) level = 1
          index_ = int(level * (steps - 1) + 0.5) + 1
          line = line substr(ramp, index_, 1)
        }
        # The star is written over the wave rather than added to it, so it
        # reads as being in front. Done here, while every row is still exactly
        # `width` characters, because the trailing trim below would otherwise
        # have to be undone to place anything.
        if (star_x >= 0 && star_y == y) {
          for (i = 0; i < length(trail); i++) {
            px = star_x - i
            if (px < 0 || px >= width) continue
            line = substr(line, 1, px) substr(trail, i + 1, 1) substr(line, px + 2)
          }
        }
        # Trailing spaces are invisible and would only be padding the frame
        # twice, so they come off before the row is handed back.
        sub(/ +$/, "", line)
        print line
      }
    }'
}

# --------------------------------------------------------------------------
# Snake
# --------------------------------------------------------------------------
#
# A state machine with no drawing in it, so that a test can play a whole game
# without a terminal and this file can be read without wondering whether the
# game is somehow reaching the installer. It is not. It has an arena, a body,
# and a piece of food, and its only output is characters.

KIBAOS_SNAKE_W=0
KIBAOS_SNAKE_H=0
KIBAOS_SNAKE_DIR=right
KIBAOS_SNAKE_BODY=()
KIBAOS_SNAKE_FOOD=
KIBAOS_SNAKE_SCORE=0
KIBAOS_SNAKE_DEAD=0
KIBAOS_SNAKE_GROW=0

kibaos_snake_new() {
  KIBAOS_SNAKE_W=${1:-40}
  KIBAOS_SNAKE_H=${2:-8}
  KIBAOS_SNAKE_DIR=right
  KIBAOS_SNAKE_SCORE=0
  KIBAOS_SNAKE_DEAD=0
  KIBAOS_SNAKE_GROW=0
  local mid_x=$(( KIBAOS_SNAKE_W / 4 )) mid_y=$(( KIBAOS_SNAKE_H / 2 ))
  KIBAOS_SNAKE_BODY=(
    "$(( mid_x + 2 )),$mid_y"
    "$(( mid_x + 1 )),$mid_y"
    "$mid_x,$mid_y"
  )
  kibaos_snake_place_food
}

# Anywhere that is not the snake. The bounded retry matters: as the body fills
# the arena, a naive loop that keeps rolling until it misses the snake takes
# unbounded time, and the one place that would show up is the moment somebody
# is about to win.
kibaos_snake_place_food() {
  local attempt x y candidate cell taken
  for (( attempt = 0; attempt < 200; attempt++ )); do
    x=$(( RANDOM % KIBAOS_SNAKE_W ))
    y=$(( RANDOM % KIBAOS_SNAKE_H ))
    candidate="$x,$y"
    taken=0
    for cell in "${KIBAOS_SNAKE_BODY[@]}"; do
      [[ $cell != "$candidate" ]] || { taken=1; break; }
    done
    (( taken )) || { KIBAOS_SNAKE_FOOD=$candidate; return 0; }
  done
  # The arena is full. That is a win, and there is nowhere left to put food.
  KIBAOS_SNAKE_FOOD=
  return 0
}

# Turning back on yourself is the one input a snake ignores, because it is
# always a mistake rather than a request.
kibaos_snake_turn() {
  case $1 in
    up)    [[ $KIBAOS_SNAKE_DIR == down  ]] || KIBAOS_SNAKE_DIR=up ;;
    down)  [[ $KIBAOS_SNAKE_DIR == up    ]] || KIBAOS_SNAKE_DIR=down ;;
    left)  [[ $KIBAOS_SNAKE_DIR == right ]] || KIBAOS_SNAKE_DIR=left ;;
    right) [[ $KIBAOS_SNAKE_DIR == left  ]] || KIBAOS_SNAKE_DIR=right ;;
  esac
}

# One tick. Returns 1 once the snake has died, and keeps returning 1.
kibaos_snake_step() {
  (( ! KIBAOS_SNAKE_DEAD )) || return 1
  local head=${KIBAOS_SNAKE_BODY[0]} x y cell
  x=${head%,*}
  y=${head#*,}
  case $KIBAOS_SNAKE_DIR in
    up)    y=$(( y - 1 )) ;;
    down)  y=$(( y + 1 )) ;;
    left)  x=$(( x - 1 )) ;;
    right) x=$(( x + 1 )) ;;
  esac
  # The walls are walls. Wrapping would make the game easier and the arena
  # harder to read, and the border is drawn, so it should mean something.
  if (( x < 0 || y < 0 || x >= KIBAOS_SNAKE_W || y >= KIBAOS_SNAKE_H )); then
    KIBAOS_SNAKE_DEAD=1
    return 1
  fi
  # The tail cell is about to move out from under the head unless the snake is
  # growing, so it does not count as a collision.
  local limit=$(( ${#KIBAOS_SNAKE_BODY[@]} - 1 ))
  (( KIBAOS_SNAKE_GROW )) && limit=${#KIBAOS_SNAKE_BODY[@]}
  local i
  for (( i = 0; i < limit; i++ )); do
    cell=${KIBAOS_SNAKE_BODY[i]}
    [[ $cell != "$x,$y" ]] || { KIBAOS_SNAKE_DEAD=1; return 1; }
  done

  KIBAOS_SNAKE_BODY=("$x,$y" "${KIBAOS_SNAKE_BODY[@]}")
  if [[ -n $KIBAOS_SNAKE_FOOD && $KIBAOS_SNAKE_FOOD == "$x,$y" ]]; then
    KIBAOS_SNAKE_SCORE=$(( KIBAOS_SNAKE_SCORE + 1 ))
    kibaos_snake_place_food
  else
    unset 'KIBAOS_SNAKE_BODY[-1]'
    KIBAOS_SNAKE_BODY=("${KIBAOS_SNAKE_BODY[@]}")
  fi
  KIBAOS_SNAKE_GROW=0
  return 0
}

# The arena as rows of characters, no border and no padding. Whoever is drawing
# owns the frame.
kibaos_snake_rows() {
  local -A cells=()
  local cell first=1 x y row
  for cell in "${KIBAOS_SNAKE_BODY[@]}"; do
    if (( first )); then
      cells[$cell]='@'
      first=0
    else
      cells[$cell]='o'
    fi
  done
  [[ -z $KIBAOS_SNAKE_FOOD ]] || cells[$KIBAOS_SNAKE_FOOD]='*'
  for (( y = 0; y < KIBAOS_SNAKE_H; y++ )); do
    row=''
    for (( x = 0; x < KIBAOS_SNAKE_W; x++ )); do
      row+=${cells["$x,$y"]:-.}
    done
    printf '%s\n' "$row"
  done
}

# --------------------------------------------------------------------------
# 2048
# --------------------------------------------------------------------------
#
# The best fit that exists for this screen, and it is not close.
#
# Four keys, no timing, and a 4x4 grid that renders exactly in a terminal.
# Everybody already knows the rules, so there is nothing to explain on a screen
# nobody came here to read. And it is satisfying in the particular low stakes
# way a waiting screen wants: you can stop mid-move, look at the install, and
# come back without having lost anything.
#
# The constraint that ruled out the obvious alternatives is that this screen
# redraws on a fixed tick. Anything needing input latency is out, which is why
# there is no Tetris here: a laggy Tetris is worse than no Tetris.
#
# The board is a flat 16 cell array, row major. A shell has no 2D arrays and
# faking one with name references costs more than the index arithmetic does.
KIBAOS_2048_BOARD=()
KIBAOS_2048_SCORE=0
KIBAOS_2048_WON=0
KIBAOS_2048_MOVED=0

kibaos_2048_new() {
  local i
  KIBAOS_2048_BOARD=()
  for (( i = 0; i < 16; i++ )); do KIBAOS_2048_BOARD+=(0); done
  KIBAOS_2048_SCORE=0
  KIBAOS_2048_WON=0
  kibaos_2048_spawn
  kibaos_2048_spawn
}

# A new tile in a free cell. Nine times in ten a 2, which is the standard
# distribution and the reason the game is winnable at all.
kibaos_2048_spawn() {
  local free=() i
  for (( i = 0; i < 16; i++ )); do
    (( KIBAOS_2048_BOARD[i] != 0 )) || free+=("$i")
  done
  (( ${#free[@]} )) || return 1
  i=${free[RANDOM % ${#free[@]}]}
  if (( RANDOM % 10 )); then
    KIBAOS_2048_BOARD[i]=2
  else
    KIBAOS_2048_BOARD[i]=4
  fi
}

# Collapse one line of four toward index 0.
#
# Written once and used for all four directions by handing it the indices in
# the right order, because four nearly identical loops is four places for the
# merge rule to drift. A tile merges at most once per move, which is the rule
# everybody gets wrong: 2 2 4 does not become 8.
_kibaos_2048_line() {
  local -n _cells=$1
  local packed=() i value merged=0
  for i in "${_cells[@]}"; do
    (( KIBAOS_2048_BOARD[i] != 0 )) || continue
    packed+=("${KIBAOS_2048_BOARD[i]}")
  done
  local out=() n=${#packed[@]}
  i=0
  while (( i < n )); do
    if (( i + 1 < n && packed[i] == packed[i+1] )); then
      value=$(( packed[i] * 2 ))
      out+=("$value")
      KIBAOS_2048_SCORE=$(( KIBAOS_2048_SCORE + value ))
      (( value != 2048 )) || KIBAOS_2048_WON=1
      i=$(( i + 2 ))
    else
      out+=("${packed[i]}")
      i=$(( i + 1 ))
    fi
  done
  while (( ${#out[@]} < 4 )); do out+=(0); done
  for (( i = 0; i < 4; i++ )); do
    if (( KIBAOS_2048_BOARD[_cells[i]] != out[i] )); then
      KIBAOS_2048_MOVED=1
      KIBAOS_2048_BOARD[_cells[i]]=${out[i]}
    fi
  done
}

kibaos_2048_move() {
  local direction=$1 r c line
  KIBAOS_2048_MOVED=0
  for (( r = 0; r < 4; r++ )); do
    line=()
    for (( c = 0; c < 4; c++ )); do
      case $direction in
        left)  line+=($(( r * 4 + c ))) ;;
        right) line+=($(( r * 4 + 3 - c ))) ;;
        up)    line+=($(( c * 4 + r ))) ;;
        down)  line+=($(( (3 - c) * 4 + r ))) ;;
      esac
    done
    _kibaos_2048_line line
  done
  # A tile only appears when something actually moved. Spawning on a move that
  # did nothing is how a board fills up while somebody is pressing a key that
  # is doing nothing, which reads as the game cheating.
  (( ! KIBAOS_2048_MOVED )) || kibaos_2048_spawn
}

# Over when the board is full and no neighbours match.
kibaos_2048_over() {
  local i r c
  for (( i = 0; i < 16; i++ )); do
    (( KIBAOS_2048_BOARD[i] != 0 )) || return 1
  done
  for (( r = 0; r < 4; r++ )); do
    for (( c = 0; c < 4; c++ )); do
      i=$(( r * 4 + c ))
      (( c == 3 )) || ! (( KIBAOS_2048_BOARD[i] == KIBAOS_2048_BOARD[i+1] )) || return 1
      (( r == 3 )) || ! (( KIBAOS_2048_BOARD[i] == KIBAOS_2048_BOARD[i+4] )) || return 1
    done
  done
  return 0
}

# --------------------------------------------------------------------------
# Life
# --------------------------------------------------------------------------
#
# Conway's, as something to watch rather than something to play.
#
# This one earns its place for a reason none of the games do. Some people find
# a game on a screen they are anxious about actively stressful: they do not
# want to be entertained while a disk is being erased, they want the minutes
# to pass. A thing that moves on its own, needs nothing, and cannot be lost is
# the answer for them, and it is the only option here with all three.
#
# It is also thematically right for a screen where something is being built.
#
# The grid wraps at the edges. A bounded grid dies back to a few stable blobs
# in a corner within a minute, which is a screen that has stopped, and the
# whole point is a screen that has not.
KIBAOS_LIFE_W=0
KIBAOS_LIFE_H=0
KIBAOS_LIFE_CELLS=()
KIBAOS_LIFE_AGE=0

kibaos_life_new() {
  local w=${1:-40} h=${2:-12} i
  KIBAOS_LIFE_W=$w
  KIBAOS_LIFE_H=$h
  KIBAOS_LIFE_CELLS=()
  KIBAOS_LIFE_AGE=0
  # Around a third alive. Sparser than that takes a long time to become
  # interesting and denser than that boils for a while and then collapses.
  for (( i = 0; i < w * h; i++ )); do
    if (( RANDOM % 100 < 32 )); then
      KIBAOS_LIFE_CELLS+=(1)
    else
      KIBAOS_LIFE_CELLS+=(0)
    fi
  done
}

kibaos_life_step() {
  local w=$KIBAOS_LIFE_W h=$KIBAOS_LIFE_H
  (( w > 0 && h > 0 )) || return 0
  local -a next=()
  local x y dx dy nx ny live cell
  for (( y = 0; y < h; y++ )); do
    for (( x = 0; x < w; x++ )); do
      live=0
      for dy in -1 0 1; do
        for dx in -1 0 1; do
          (( dx || dy )) || continue
          # The wrap, which is what keeps this alive for ten minutes.
          nx=$(( (x + dx + w) % w ))
          ny=$(( (y + dy + h) % h ))
          (( ! KIBAOS_LIFE_CELLS[ny * w + nx] )) || live=$(( live + 1 ))
        done
      done
      cell=${KIBAOS_LIFE_CELLS[y * w + x]}
      if (( cell )); then
        (( live == 2 || live == 3 )) && next+=(1) || next+=(0)
      else
        (( live == 3 )) && next+=(1) || next+=(0)
      fi
    done
  done
  KIBAOS_LIFE_CELLS=("${next[@]}")
  KIBAOS_LIFE_AGE=$(( KIBAOS_LIFE_AGE + 1 ))
}

# The grid as rows of characters, no border and no padding, the same contract
# the snake arena has: whoever is drawing owns the frame.
kibaos_life_rows() {
  local x y row
  for (( y = 0; y < KIBAOS_LIFE_H; y++ )); do
    row=''
    for (( x = 0; x < KIBAOS_LIFE_W; x++ )); do
      if (( KIBAOS_LIFE_CELLS[y * KIBAOS_LIFE_W + x] )); then row+='#'; else row+=' '; fi
    done
    printf '%s\n' "$row"
  done
}

# --------------------------------------------------------------------------
# Lights Out
# --------------------------------------------------------------------------
#
# Five by five, one action, pure logic and no timing at all. It is the
# smallest thing on this screen that is still a game, and it is the one that
# survives being interrupted best: the board is the whole state, so looking
# away for a minute costs nothing.
#
# The board is generated by starting from solved and pressing random cells,
# which is the only honest way to do it. A random board is solvable slightly
# less than half the time, and handing somebody an impossible puzzle while
# they wait for a disk is not a joke worth making.
KIBAOS_LIGHTS=()
KIBAOS_LIGHTS_MOVES=0
KIBAOS_LIGHTS_X=0
KIBAOS_LIGHTS_Y=0

_kibaos_lights_press() {
  local x=$1 y=$2 i
  for i in "$x,$y" "$(( x - 1 )),$y" "$(( x + 1 )),$y" "$x,$(( y - 1 ))" "$x,$(( y + 1 ))"; do
    local cx=${i%,*} cy=${i#*,}
    (( cx >= 0 && cx < 5 && cy >= 0 && cy < 5 )) || continue
    KIBAOS_LIGHTS[cy * 5 + cx]=$(( ! KIBAOS_LIGHTS[cy * 5 + cx] ))
  done
}

kibaos_lights_new() {
  local i
  KIBAOS_LIGHTS=()
  for (( i = 0; i < 25; i++ )); do KIBAOS_LIGHTS+=(0); done
  KIBAOS_LIGHTS_MOVES=0
  KIBAOS_LIGHTS_X=2
  KIBAOS_LIGHTS_Y=2
  # Six presses from solved. Enough to look like a puzzle, few enough that it
  # is finishable inside the wait it exists to fill.
  for (( i = 0; i < 6; i++ )); do
    _kibaos_lights_press "$(( RANDOM % 5 ))" "$(( RANDOM % 5 ))"
  done
  # A generated board that happens to come out solved is not a puzzle.
  kibaos_lights_won && kibaos_lights_new
  return 0
}

kibaos_lights_move() {
  case $1 in
    up)    (( KIBAOS_LIGHTS_Y > 0 )) && KIBAOS_LIGHTS_Y=$(( KIBAOS_LIGHTS_Y - 1 )) || true ;;
    down)  (( KIBAOS_LIGHTS_Y < 4 )) && KIBAOS_LIGHTS_Y=$(( KIBAOS_LIGHTS_Y + 1 )) || true ;;
    left)  (( KIBAOS_LIGHTS_X > 0 )) && KIBAOS_LIGHTS_X=$(( KIBAOS_LIGHTS_X - 1 )) || true ;;
    right) (( KIBAOS_LIGHTS_X < 4 )) && KIBAOS_LIGHTS_X=$(( KIBAOS_LIGHTS_X + 1 )) || true ;;
  esac
  return 0
}

kibaos_lights_toggle() {
  _kibaos_lights_press "$KIBAOS_LIGHTS_X" "$KIBAOS_LIGHTS_Y"
  KIBAOS_LIGHTS_MOVES=$(( KIBAOS_LIGHTS_MOVES + 1 ))
}

kibaos_lights_won() {
  local cell
  for cell in "${KIBAOS_LIGHTS[@]}"; do
    (( ! cell )) || return 1
  done
  return 0
}

# Rows of characters. The cursor is drawn as brackets around a cell rather
# than as a colour, so it is still visible with the colour gone.
kibaos_lights_rows() {
  local x y row lit left right
  for (( y = 0; y < 5; y++ )); do
    row=''
    for (( x = 0; x < 5; x++ )); do
      if (( KIBAOS_LIGHTS[y * 5 + x] )); then lit='O'; else lit='.'; fi
      left=' '; right=' '
      if (( x == KIBAOS_LIGHTS_X && y == KIBAOS_LIGHTS_Y )); then left='['; right=']'; fi
      row+="$left$lit$right"
    done
    printf '%s\n' "$row"
  done
}

# --------------------------------------------------------------------------
# The fifteen puzzle
# --------------------------------------------------------------------------
#
# Arrows only, and everybody already knows it, which is the same argument that
# put 2048 on this screen. It renders in sixteen cells and has no clock.
#
# Shuffled by making legal moves from the solved board rather than by
# permuting the tiles. Half of all permutations of a fifteen puzzle cannot be
# solved, and the parity rule that decides which half is not something to
# explain to somebody waiting for an install.
KIBAOS_FIFTEEN=()
KIBAOS_FIFTEEN_HOLE=15
KIBAOS_FIFTEEN_MOVES=0

kibaos_fifteen_new() {
  local i last=''
  KIBAOS_FIFTEEN=()
  for (( i = 1; i <= 15; i++ )); do KIBAOS_FIFTEEN+=("$i"); done
  KIBAOS_FIFTEEN+=(0)
  KIBAOS_FIFTEEN_HOLE=15
  KIBAOS_FIFTEEN_MOVES=0
  local n direction
  for (( n = 0; n < 120; n++ )); do
    # Never immediately undoing the move just made, or a hundred and twenty
    # shuffles average out to about six.
    while true; do
      case $(( RANDOM % 4 )) in
        0) direction=up ;; 1) direction=down ;;
        2) direction=left ;; *) direction=right ;;
      esac
      [[ $direction != "$last" ]] || continue
      break
    done
    if kibaos_fifteen_slide "$direction"; then
      case $direction in
        up) last=down ;; down) last=up ;;
        left) last=right ;; right) last=left ;;
      esac
    fi
  done
  KIBAOS_FIFTEEN_MOVES=0
  return 0
}

# The direction names the tile's travel, not the hole's, because that is what
# somebody pressing an arrow means by it.
kibaos_fifteen_slide() {
  local hole=$KIBAOS_FIFTEEN_HOLE from
  local hx=$(( hole % 4 )) hy=$(( hole / 4 ))
  case $1 in
    up)    (( hy < 3 )) || return 1; from=$(( hole + 4 )) ;;
    down)  (( hy > 0 )) || return 1; from=$(( hole - 4 )) ;;
    left)  (( hx < 3 )) || return 1; from=$(( hole + 1 )) ;;
    right) (( hx > 0 )) || return 1; from=$(( hole - 1 )) ;;
    *) return 1 ;;
  esac
  KIBAOS_FIFTEEN[hole]=${KIBAOS_FIFTEEN[from]}
  KIBAOS_FIFTEEN[from]=0
  KIBAOS_FIFTEEN_HOLE=$from
  KIBAOS_FIFTEEN_MOVES=$(( KIBAOS_FIFTEEN_MOVES + 1 ))
  return 0
}

kibaos_fifteen_won() {
  local i
  for (( i = 0; i < 15; i++ )); do
    (( KIBAOS_FIFTEEN[i] == i + 1 )) || return 1
  done
  return 0
}

kibaos_fifteen_rows() {
  local x y row cell
  for (( y = 0; y < 4; y++ )); do
    row=''
    for (( x = 0; x < 4; x++ )); do
      cell=${KIBAOS_FIFTEEN[y * 4 + x]}
      if (( cell )); then
        row+=$(printf '%4s' "$cell")
      else
        row+='    '
      fi
    done
    printf '%s\n' "$row"
  done
}

# --------------------------------------------------------------------------
# Minesweeper
# --------------------------------------------------------------------------
#
# A grid, a cursor and two actions, with no clock anywhere in it. Nine by nine
# with ten mines, which is the beginner board everybody has already played.
#
# The mines are placed after the first reveal, not before, and never under it.
# Losing on the first keypress of a game somebody started to pass the time is
# the single most annoying thing this screen could do, and the fix is three
# lines. Every implementation that gets this wrong got it wrong by placing
# first because that is the obvious order.
KIBAOS_MINE_W=9
KIBAOS_MINE_H=9
KIBAOS_MINE_COUNT=10
KIBAOS_MINES=()
KIBAOS_MINE_SHOWN=()
KIBAOS_MINE_FLAG=()
KIBAOS_MINE_X=4
KIBAOS_MINE_Y=4
KIBAOS_MINE_STARTED=0
KIBAOS_MINE_DEAD=0
KIBAOS_MINE_WON=0

kibaos_mines_new() {
  local i
  KIBAOS_MINES=(); KIBAOS_MINE_SHOWN=(); KIBAOS_MINE_FLAG=()
  for (( i = 0; i < KIBAOS_MINE_W * KIBAOS_MINE_H; i++ )); do
    KIBAOS_MINES+=(0); KIBAOS_MINE_SHOWN+=(0); KIBAOS_MINE_FLAG+=(0)
  done
  KIBAOS_MINE_X=$(( KIBAOS_MINE_W / 2 ))
  KIBAOS_MINE_Y=$(( KIBAOS_MINE_H / 2 ))
  KIBAOS_MINE_STARTED=0
  KIBAOS_MINE_DEAD=0
  KIBAOS_MINE_WON=0
}

# Mines everywhere except the cell just opened and the ring around it, so the
# first reveal always opens something.
_kibaos_mines_place() {
  local safe_x=$1 safe_y=$2 placed=0 x y index
  while (( placed < KIBAOS_MINE_COUNT )); do
    x=$(( RANDOM % KIBAOS_MINE_W ))
    y=$(( RANDOM % KIBAOS_MINE_H ))
    (( x < safe_x - 1 || x > safe_x + 1 || y < safe_y - 1 || y > safe_y + 1 )) || continue
    index=$(( y * KIBAOS_MINE_W + x ))
    (( ! KIBAOS_MINES[index] )) || continue
    KIBAOS_MINES[index]=1
    placed=$(( placed + 1 ))
  done
  KIBAOS_MINE_STARTED=1
}

kibaos_mines_near() {
  local x=$1 y=$2 dx dy nx ny near=0
  for dy in -1 0 1; do
    for dx in -1 0 1; do
      (( dx || dy )) || continue
      nx=$(( x + dx )); ny=$(( y + dy ))
      (( nx >= 0 && nx < KIBAOS_MINE_W && ny >= 0 && ny < KIBAOS_MINE_H )) || continue
      (( ! KIBAOS_MINES[ny * KIBAOS_MINE_W + nx] )) || near=$(( near + 1 ))
    done
  done
  printf '%s' "$near"
}

# Opening an empty cell opens its neighbours too, which is the whole game.
# Iterative rather than recursive: bash recursion at eighty deep is slow
# enough to be visible on a screen redrawing eight times a second.
_kibaos_mines_open() {
  local -a queue=("$1,$2")
  local item x y index near dx dy nx ny
  while (( ${#queue[@]} )); do
    item=${queue[0]}
    queue=("${queue[@]:1}")
    x=${item%,*}; y=${item#*,}
    index=$(( y * KIBAOS_MINE_W + x ))
    (( ! KIBAOS_MINE_SHOWN[index] )) || continue
    (( ! KIBAOS_MINE_FLAG[index] )) || continue
    KIBAOS_MINE_SHOWN[index]=1
    near=$(kibaos_mines_near "$x" "$y")
    (( near == 0 )) || continue
    for dy in -1 0 1; do
      for dx in -1 0 1; do
        (( dx || dy )) || continue
        nx=$(( x + dx )); ny=$(( y + dy ))
        (( nx >= 0 && nx < KIBAOS_MINE_W && ny >= 0 && ny < KIBAOS_MINE_H )) || continue
        queue+=("$nx,$ny")
      done
    done
  done
}

kibaos_mines_reveal() {
  local index=$(( KIBAOS_MINE_Y * KIBAOS_MINE_W + KIBAOS_MINE_X ))
  (( ! KIBAOS_MINE_DEAD && ! KIBAOS_MINE_WON )) || return 0
  (( ! KIBAOS_MINE_FLAG[index] )) || return 0
  (( KIBAOS_MINE_STARTED )) || _kibaos_mines_place "$KIBAOS_MINE_X" "$KIBAOS_MINE_Y"
  if (( KIBAOS_MINES[index] )); then
    KIBAOS_MINE_DEAD=1
    return 0
  fi
  _kibaos_mines_open "$KIBAOS_MINE_X" "$KIBAOS_MINE_Y"
  # Explicitly, because `kibaos_mines_check` reports "not won yet" as a
  # non-zero status and this function would otherwise hand that to its caller
  # as a failure. Under errexit that is not a subtle bug: it ends the program
  # on the first move of a game.
  kibaos_mines_check || true
  return 0
}

kibaos_mines_flag() {
  local index=$(( KIBAOS_MINE_Y * KIBAOS_MINE_W + KIBAOS_MINE_X ))
  (( ! KIBAOS_MINE_DEAD && ! KIBAOS_MINE_WON )) || return 0
  (( ! KIBAOS_MINE_SHOWN[index] )) || return 0
  KIBAOS_MINE_FLAG[index]=$(( ! KIBAOS_MINE_FLAG[index] ))
  return 0
}

# Won when every cell that is not a mine has been opened. Flags are not part
# of it: a board can be finished without planting one, and requiring them
# would be inventing a rule.
kibaos_mines_check() {
  local i
  for (( i = 0; i < KIBAOS_MINE_W * KIBAOS_MINE_H; i++ )); do
    (( KIBAOS_MINES[i] || KIBAOS_MINE_SHOWN[i] )) || return 1
  done
  KIBAOS_MINE_WON=1
  return 0
}

kibaos_mines_move() {
  case $1 in
    up)    (( KIBAOS_MINE_Y > 0 )) && KIBAOS_MINE_Y=$(( KIBAOS_MINE_Y - 1 )) || true ;;
    down)  (( KIBAOS_MINE_Y < KIBAOS_MINE_H - 1 )) && KIBAOS_MINE_Y=$(( KIBAOS_MINE_Y + 1 )) || true ;;
    left)  (( KIBAOS_MINE_X > 0 )) && KIBAOS_MINE_X=$(( KIBAOS_MINE_X - 1 )) || true ;;
    right) (( KIBAOS_MINE_X < KIBAOS_MINE_W - 1 )) && KIBAOS_MINE_X=$(( KIBAOS_MINE_X + 1 )) || true ;;
  esac
  return 0
}

kibaos_mines_rows() {
  local x y row index cell near left right
  for (( y = 0; y < KIBAOS_MINE_H; y++ )); do
    row=''
    for (( x = 0; x < KIBAOS_MINE_W; x++ )); do
      index=$(( y * KIBAOS_MINE_W + x ))
      if (( KIBAOS_MINE_DEAD && KIBAOS_MINES[index] )); then
        cell='*'
      elif (( KIBAOS_MINE_FLAG[index] )); then
        cell='F'
      elif (( ! KIBAOS_MINE_SHOWN[index] )); then
        cell='#'
      else
        near=$(kibaos_mines_near "$x" "$y")
        (( near )) && cell=$near || cell='.'
      fi
      left=' '; right=' '
      if (( x == KIBAOS_MINE_X && y == KIBAOS_MINE_Y )); then left='['; right=']'; fi
      row+="$left$cell$right"
    done
    printf '%s\n' "$row"
  done
}

# --------------------------------------------------------------------------
# Nonogram
# --------------------------------------------------------------------------
#
# Picross, in text, and the one thing on this screen that rewards a ten minute
# window rather than being interrupted by one. Pure logic, no timing, and
# every step of it is deduction rather than guessing.
#
# The pictures are drawn by hand rather than generated. A random grid produces
# clues that are technically solvable and give no satisfaction at all, because
# the reward for finishing a nonogram is seeing what it was, and a random one
# is never anything. Eight by eight, which is small enough to finish while a
# disk is being written and large enough to be a picture.
# One picture per line, a row of the grid between each colon, so that the
# pictures are legible in the source. A wall of dots on one line is not, and
# the whole point of these is that somebody drew them. The set is deliberately
# small enough that every picture can be recognized at eight by eight.
# --------------------------------------------------------------------------
# Sudoku
#
# The puzzles are data, identical to the graphical installer's, rather than
# something generated here. A generator has to be trusted; a fixed set can be
# checked, and the test proves every one of these has exactly one solution.
# That matters more here than in any other game on this card, because a sudoku
# with two answers tells somebody they are wrong when they are not.
#
# No solver ships with the game. Because the answer is unique, a full grid
# with nothing repeated in any row, column or box is the answer.
# --------------------------------------------------------------------------

KIBAOS_SUDOKU=(
  'gentle1:.7.9.21..2187..3.4596..47.29.7....4..6.....2..4....8.16.94..5187.4..9236..12.5.7.'
  'gentle2:.7.8..5..5.2..9.76.8.57..348...1....326.8.715....5...323..98.5.16.3..9.8..8..7.2.'
  'steady3:48.......925.4..73.7158.....34....2....756....1....58.....6813.16..9.748.......62'
  'steady4:...4.1..5.....8317...3.2.84.4.....68..65.31..92.....7.36.7.9...8941.....2..6.4...'
  'steady5:..6..5.175....19...12...5..2..7....976.2.8.311....4..6..4...19...51....863.9..7..'
  'firm6:7.35.8..........7.9.5.7.8...47.92.3.....5.....3.61.75...8.6.4.3.6..........2.51.8'
  'firm7:.81..96..2.3..6....7...5.....7..314...8.5.7...367..9.....8...1....4..5.7..25..38.'
  'firm8:...4..5232.........5...168.3...4..7...6.1.9...9..2...5.781...9.........8931..8...'
)
KIBAOS_SUDOKU_N=9
KIBAOS_SUDOKU_CELLS=()
KIBAOS_SUDOKU_GIVEN=()
KIBAOS_SUDOKU_X=0
KIBAOS_SUDOKU_Y=0
KIBAOS_SUDOKU_MOVES=0
KIBAOS_SUDOKU_NAME=

kibaos_sudoku_new() {
  local entry text ch i
  entry=${KIBAOS_SUDOKU[RANDOM % ${#KIBAOS_SUDOKU[@]}]}
  KIBAOS_SUDOKU_NAME=${entry%%:*}
  text=${entry#*:}
  KIBAOS_SUDOKU_CELLS=()
  KIBAOS_SUDOKU_GIVEN=()
  for (( i = 0; i < 81; i++ )); do
    ch=${text:i:1}
    if [[ $ch == "." ]]; then
      KIBAOS_SUDOKU_CELLS+=(0)
      KIBAOS_SUDOKU_GIVEN+=(0)
    else
      KIBAOS_SUDOKU_CELLS+=("$ch")
      KIBAOS_SUDOKU_GIVEN+=(1)
    fi
  done
  KIBAOS_SUDOKU_MOVES=0
  # Start somewhere the keys do something. A cursor parked on a given makes
  # the first press look like a broken board rather than like a rule.
  KIBAOS_SUDOKU_X=0
  KIBAOS_SUDOKU_Y=0
  for (( i = 0; i < 81; i++ )); do
    if (( ! KIBAOS_SUDOKU_GIVEN[i] )); then
      KIBAOS_SUDOKU_X=$(( i % 9 ))
      KIBAOS_SUDOKU_Y=$(( i / 9 ))
      break
    fi
  done
  return 0
}

# Whether this square repeats its number anywhere it may not.
kibaos_sudoku_conflict() {
  local index=$1 value=${KIBAOS_SUDOKU_CELLS[$1]}
  local row=$(( index / 9 )) col=$(( index % 9 )) step peer
  local box_row=$(( (index / 9 / 3) * 3 )) box_col=$(( (index % 9) / 3 * 3 ))
  (( value )) || return 1
  for (( step = 0; step < 9; step++ )); do
    peer=$(( row * 9 + step ))
    (( peer == index )) || (( KIBAOS_SUDOKU_CELLS[peer] != value )) || return 0
    peer=$(( step * 9 + col ))
    (( peer == index )) || (( KIBAOS_SUDOKU_CELLS[peer] != value )) || return 0
  done
  local dy dx
  for (( dy = 0; dy < 3; dy++ )); do
    for (( dx = 0; dx < 3; dx++ )); do
      peer=$(( (box_row + dy) * 9 + box_col + dx ))
      (( peer == index )) || (( KIBAOS_SUDOKU_CELLS[peer] != value )) || return 0
    done
  done
  return 1
}

kibaos_sudoku_conflicts() {
  local i count=0
  for (( i = 0; i < 81; i++ )); do
    kibaos_sudoku_conflict "$i" && count=$(( count + 1 ))
  done
  printf '%s' "$count"
}

kibaos_sudoku_left() {
  local i count=0
  for (( i = 0; i < 81; i++ )); do
    (( KIBAOS_SUDOKU_CELLS[i] )) || count=$(( count + 1 ))
  done
  printf '%s' "$count"
}

kibaos_sudoku_won() {
  local i
  for (( i = 0; i < 81; i++ )); do
    (( KIBAOS_SUDOKU_CELLS[i] )) || return 1
  done
  for (( i = 0; i < 81; i++ )); do
    kibaos_sudoku_conflict "$i" && return 1
  done
  return 0
}

kibaos_sudoku_move() {
  case $1 in
    up)    (( KIBAOS_SUDOKU_Y > 0 )) && KIBAOS_SUDOKU_Y=$(( KIBAOS_SUDOKU_Y - 1 )) || true ;;
    down)  (( KIBAOS_SUDOKU_Y < 8 )) && KIBAOS_SUDOKU_Y=$(( KIBAOS_SUDOKU_Y + 1 )) || true ;;
    left)  (( KIBAOS_SUDOKU_X > 0 )) && KIBAOS_SUDOKU_X=$(( KIBAOS_SUDOKU_X - 1 )) || true ;;
    right) (( KIBAOS_SUDOKU_X < 8 )) && KIBAOS_SUDOKU_X=$(( KIBAOS_SUDOKU_X + 1 )) || true ;;
  esac
  return 0
}

# Writing the same number again rubs it out, so one key both writes and
# corrects and nobody has to find the other one.
kibaos_sudoku_write() {
  local value=$1 index=$(( KIBAOS_SUDOKU_Y * 9 + KIBAOS_SUDOKU_X ))
  (( KIBAOS_SUDOKU_GIVEN[index] )) && return 0
  if (( value == 0 )); then
    (( KIBAOS_SUDOKU_CELLS[index] )) || return 0
    KIBAOS_SUDOKU_CELLS[index]=0
  elif (( KIBAOS_SUDOKU_CELLS[index] == value )); then
    KIBAOS_SUDOKU_CELLS[index]=0
  else
    KIBAOS_SUDOKU_CELLS[index]=$value
  fi
  KIBAOS_SUDOKU_MOVES=$(( KIBAOS_SUDOKU_MOVES + 1 ))
  return 0
}

KIBAOS_NONO_ART=(
  'heart:.##..##.:########:########:########:.######.:..####..:...##...:........'
  'cat:#......#:##....##:########:#.#..#.#:########:.######.:..#..#..:........'
  'key:..####..:.#....#.:.#....#.:..####..:...##...:...####.:...##...:...###..'
  'up:...##...:..####..:.######.:########:...##...:...##...:...##...:...##...'
  'wave:........:..##....:.####.#.:########:########:.######.:..####..:........'
  'die:########:#......#:#.##...#:#......#:#...##.#:#......#:#......#:########'
  'sun:...##...:..####..:.######.:########:.######.:..####..:...##...:........'
  'house:....#...:...###..:..#####.:########:##..#..#:##..#..#:########:........'
  'smile:.######.:#......#:#.#..#.#:#......#:#.#..#.#:#..##..#:.#....#.:..####..'
  'flower:...##...:...##...:..####..:.######.:...##...:..####..:.#....#.:#......#'
  'rocket:...##...:..####..:..####..:.######.:########:...##...:..#..#..:.#....#.'
  'star:...#....:..###...:.#####..:#######.:.#####..:..###...:...#....:........'
  'tree:...##...:..####..:.######.:########:..####..:.######.:...##...:...##...'
  'mug:........:######..:#....###:#....#.#:#....###:######..:.####...:........'
  'boat:....#...:...##...:..###...:.####...:....#...:........:########:.######.'
  'bell:...##...:..####..:..####..:.######.:.######.:########:........:...##...'
  'letter:........:########:##....##:#.#..#.#:#..##..#:#......#:########:........'
  'anchor:...##...:...##...:.######.:...##...:#..##..#:#..##..#:##....##:.######.'
  'disk:########:#..##..#:#..##..#:#......#:#.####.#:#.#..#.#:#.####.#:########'
  'battery:........:...##...:########:##.##.##:##.##.##:##.##.##:########:........'
)
KIBAOS_NONO_W=8
KIBAOS_NONO_H=8
KIBAOS_NONO_SOLUTION=()
KIBAOS_NONO_MARKS=()
KIBAOS_NONO_X=0
KIBAOS_NONO_Y=0
KIBAOS_NONO_NAME=

kibaos_nono_new() {
  local entry rows row x y
  local -a _nono_rows=()
  entry=${KIBAOS_NONO_ART[RANDOM % ${#KIBAOS_NONO_ART[@]}]}
  KIBAOS_NONO_NAME=${entry%%:*}
  rows=${entry#*:}
  KIBAOS_NONO_SOLUTION=()
  KIBAOS_NONO_MARKS=()
  IFS=':' read -r -a _nono_rows <<<"$rows"
  for (( y = 0; y < KIBAOS_NONO_H; y++ )); do
    row=${_nono_rows[y]}
    for (( x = 0; x < KIBAOS_NONO_W; x++ )); do
      if [[ ${row:x:1} == '#' ]]; then
        KIBAOS_NONO_SOLUTION+=(1)
      else
        KIBAOS_NONO_SOLUTION+=(0)
      fi
      # 0 unknown, 1 filled, 2 ruled out
      KIBAOS_NONO_MARKS+=(0)
    done
  done
  KIBAOS_NONO_X=0
  KIBAOS_NONO_Y=0
  return 0
}

# The runs of filled cells along one line, which is what a clue is.
_kibaos_nono_runs() {
  local -n _cells=$1
  local out='' run=0 cell
  for cell in "${_cells[@]}"; do
    if (( cell )); then
      run=$(( run + 1 ))
    elif (( run )); then
      out+="$run "
      run=0
    fi
  done
  (( ! run )) || out+="$run "
  [[ -n $out ]] || out='0 '
  printf '%s' "${out% }"
}

kibaos_nono_row_clue() {
  local y=$1 x
  local -a cells=()
  for (( x = 0; x < KIBAOS_NONO_W; x++ )); do
    cells+=("${KIBAOS_NONO_SOLUTION[y * KIBAOS_NONO_W + x]}")
  done
  _kibaos_nono_runs cells
}

kibaos_nono_col_clue() {
  local x=$1 y
  local -a cells=()
  for (( y = 0; y < KIBAOS_NONO_H; y++ )); do
    cells+=("${KIBAOS_NONO_SOLUTION[y * KIBAOS_NONO_W + x]}")
  done
  _kibaos_nono_runs cells
}

kibaos_nono_move() {
  case $1 in
    up)    (( KIBAOS_NONO_Y > 0 )) && KIBAOS_NONO_Y=$(( KIBAOS_NONO_Y - 1 )) || true ;;
    down)  (( KIBAOS_NONO_Y < KIBAOS_NONO_H - 1 )) && KIBAOS_NONO_Y=$(( KIBAOS_NONO_Y + 1 )) || true ;;
    left)  (( KIBAOS_NONO_X > 0 )) && KIBAOS_NONO_X=$(( KIBAOS_NONO_X - 1 )) || true ;;
    right) (( KIBAOS_NONO_X < KIBAOS_NONO_W - 1 )) && KIBAOS_NONO_X=$(( KIBAOS_NONO_X + 1 )) || true ;;
  esac
  return 0
}

# Unknown, filled, ruled out, and back. One key rather than two, because two
# keys on a grid means remembering which is which.
kibaos_nono_cycle() {
  local index=$(( KIBAOS_NONO_Y * KIBAOS_NONO_W + KIBAOS_NONO_X ))
  KIBAOS_NONO_MARKS[index]=$(( (KIBAOS_NONO_MARKS[index] + 1) % 3 ))
  return 0
}

# Solved when every filled cell is filled. Cells ruled out are not checked:
# they are the player's notes, not their answer, and finishing a picture
# without using them is a legitimate way to play.
kibaos_nono_won() {
  local i
  for (( i = 0; i < KIBAOS_NONO_W * KIBAOS_NONO_H; i++ )); do
    if (( KIBAOS_NONO_SOLUTION[i] )); then
      (( KIBAOS_NONO_MARKS[i] == 1 )) || return 1
    else
      (( KIBAOS_NONO_MARKS[i] != 1 )) || return 1
    fi
  done
  return 0
}

# --------------------------------------------------------------------------
# The typing test
# --------------------------------------------------------------------------
#
# The keyboard layout check wearing a game's clothes, which is why it is here
# twice over: somebody who plays this for two minutes has proved their layout
# is right far more thoroughly than the field after the layout question can.
#
# The phrases are chosen for coverage rather than for wit. Between them they
# use every letter and the punctuation that moves between layouts, which is
# the punctuation a disk passphrase is made of.
KIBAOS_TYPE_PHRASES=(
  'The quick brown fox jumps over the lazy dog.'
  'Pack my box with five dozen liquid jars.'
  'How vexingly quick daft zebras jump!'
  'Sphinx of black quartz, judge my vow.'
  'Waltz, bad nymph, for quick jigs vex.'
)
KIBAOS_TYPE_TARGET=
KIBAOS_TYPE_TYPED=
KIBAOS_TYPE_WRONG=0
KIBAOS_TYPE_STARTED=0

kibaos_type_new() {
  KIBAOS_TYPE_TARGET=${KIBAOS_TYPE_PHRASES[RANDOM % ${#KIBAOS_TYPE_PHRASES[@]}]}
  KIBAOS_TYPE_TYPED=''
  KIBAOS_TYPE_WRONG=0
  KIBAOS_TYPE_STARTED=0
  return 0
}

# Wrong characters are counted and kept, not rejected. A test that refuses the
# wrong key tells somebody their layout is fine by making it impossible to
# demonstrate that it is not, which is the opposite of what this is for.
kibaos_type_key() {
  local char=$1 want
  [[ ${#char} -eq 1 ]] || return 0
  (( KIBAOS_TYPE_STARTED )) || KIBAOS_TYPE_STARTED=${EPOCHSECONDS:-0}
  want=${KIBAOS_TYPE_TARGET:${#KIBAOS_TYPE_TYPED}:1}
  [[ $char == "$want" ]] || KIBAOS_TYPE_WRONG=$(( KIBAOS_TYPE_WRONG + 1 ))
  KIBAOS_TYPE_TYPED+=$char
  return 0
}

kibaos_type_back() {
  KIBAOS_TYPE_TYPED=${KIBAOS_TYPE_TYPED%?}
  return 0
}

kibaos_type_done() {
  (( ${#KIBAOS_TYPE_TYPED} >= ${#KIBAOS_TYPE_TARGET} ))
}

# What was typed, with each character marked against the phrase. Two lines
# rather than colour, so it survives having the colour taken away: the second
# line carries a caret under everything that came out wrong.
kibaos_type_marks() {
  local i out=''
  for (( i = 0; i < ${#KIBAOS_TYPE_TYPED}; i++ )); do
    if [[ ${KIBAOS_TYPE_TYPED:i:1} == "${KIBAOS_TYPE_TARGET:i:1}" ]]; then
      out+=' '
    else
      out+='^'
    fi
  done
  printf '%s' "$out"
}

kibaos_type_seconds() {
  local now=${EPOCHSECONDS:-0}
  (( KIBAOS_TYPE_STARTED )) || { printf '0'; return 0; }
  printf '%s' "$(( now - KIBAOS_TYPE_STARTED ))"
}

# --------------------------------------------------------------------------
# Sokoban
# --------------------------------------------------------------------------
#
# Arrows only, no clock, and levels, which is what earns it a place on a list
# where anything needing input latency was ruled out. Push a box onto a target.
# A box against a wall with a target elsewhere is stuck, so there is an undo,
# because a puzzle you can permanently ruin on move three while half watching a
# progress bar is a puzzle that makes the wait worse.
#
# Three levels, small enough to fit the frame at its narrowest and each one
# solvable in a handful of pushes. `#` wall, `.` target, `$` box, `@` player,
# `*` box already on a target.
KIBAOS_SOKO_LEVELS=(
  '#######|#     #|# @$. #|#     #|#######'
  '#######|#  .  #|#  $  #|# @   #|#     #|#######'
  '########|#  ..  #|#  $$  #|#      #|#  @   #|#      #|########'
)

KIBAOS_SOKO_STATIC=()
KIBAOS_SOKO_BOXES=()
KIBAOS_SOKO_W=0
KIBAOS_SOKO_H=0
KIBAOS_SOKO_X=0
KIBAOS_SOKO_Y=0
KIBAOS_SOKO_MOVES=0
KIBAOS_SOKO_LEVEL=0
KIBAOS_SOKO_UNDO=()

#: Read one level into the two grids and the player position.
kibaos_soko_new() {
  local level=${1:-$KIBAOS_SOKO_LEVEL} text rows row x y cell
  (( level >= 0 && level < ${#KIBAOS_SOKO_LEVELS[@]} )) || level=0
  KIBAOS_SOKO_LEVEL=$level
  text=${KIBAOS_SOKO_LEVELS[level]}
  IFS='|' read -r -a rows <<<"$text"
  KIBAOS_SOKO_H=${#rows[@]}
  KIBAOS_SOKO_W=0
  for row in "${rows[@]}"; do
    (( ${#row} <= KIBAOS_SOKO_W )) || KIBAOS_SOKO_W=${#row}
  done
  KIBAOS_SOKO_STATIC=()
  KIBAOS_SOKO_BOXES=()
  KIBAOS_SOKO_MOVES=0
  KIBAOS_SOKO_UNDO=()
  for (( y = 0; y < KIBAOS_SOKO_H; y++ )); do
    row=${rows[y]}
    for (( x = 0; x < KIBAOS_SOKO_W; x++ )); do
      cell=${row:x:1}
      # A short row is floor to its right rather than a ragged edge.
      [[ -n $cell ]] || cell=' '
      case $cell in
        '#') KIBAOS_SOKO_STATIC+=('#'); KIBAOS_SOKO_BOXES+=(0) ;;
        '.') KIBAOS_SOKO_STATIC+=('.'); KIBAOS_SOKO_BOXES+=(0) ;;
        '$') KIBAOS_SOKO_STATIC+=(' '); KIBAOS_SOKO_BOXES+=(1) ;;
        '*') KIBAOS_SOKO_STATIC+=('.'); KIBAOS_SOKO_BOXES+=(1) ;;
        '@') KIBAOS_SOKO_STATIC+=(' '); KIBAOS_SOKO_BOXES+=(0)
             KIBAOS_SOKO_X=$x; KIBAOS_SOKO_Y=$y ;;
        '+') KIBAOS_SOKO_STATIC+=('.'); KIBAOS_SOKO_BOXES+=(0)
             KIBAOS_SOKO_X=$x; KIBAOS_SOKO_Y=$y ;;
        *)   KIBAOS_SOKO_STATIC+=(' '); KIBAOS_SOKO_BOXES+=(0) ;;
      esac
    done
  done
  return 0
}

#: Move, pushing one box if there is one and the cell past it is free.
kibaos_soko_move() {
  local dir=$1 dx=0 dy=0 nx ny bx by here beyond
  case $dir in
    up) dy=-1 ;; down) dy=1 ;; left) dx=-1 ;; right) dx=1 ;;
    *) return 1 ;;
  esac
  nx=$(( KIBAOS_SOKO_X + dx ))
  ny=$(( KIBAOS_SOKO_Y + dy ))
  (( nx >= 0 && nx < KIBAOS_SOKO_W && ny >= 0 && ny < KIBAOS_SOKO_H )) || return 1
  here=$(( ny * KIBAOS_SOKO_W + nx ))
  [[ ${KIBAOS_SOKO_STATIC[here]} != '#' ]] || return 1
  if (( KIBAOS_SOKO_BOXES[here] )); then
    bx=$(( nx + dx ))
    by=$(( ny + dy ))
    (( bx >= 0 && bx < KIBAOS_SOKO_W && by >= 0 && by < KIBAOS_SOKO_H )) || return 1
    beyond=$(( by * KIBAOS_SOKO_W + bx ))
    [[ ${KIBAOS_SOKO_STATIC[beyond]} != '#' ]] || return 1
    (( ! KIBAOS_SOKO_BOXES[beyond] )) || return 1
    # The whole board before the push, so undo is one string rather than a
    # replay. Three levels of this fit in a variable without anybody noticing.
    KIBAOS_SOKO_UNDO+=("$KIBAOS_SOKO_X,$KIBAOS_SOKO_Y,${KIBAOS_SOKO_BOXES[*]}")
    KIBAOS_SOKO_BOXES[here]=0
    KIBAOS_SOKO_BOXES[beyond]=1
  else
    KIBAOS_SOKO_UNDO+=("$KIBAOS_SOKO_X,$KIBAOS_SOKO_Y,${KIBAOS_SOKO_BOXES[*]}")
  fi
  KIBAOS_SOKO_X=$nx
  KIBAOS_SOKO_Y=$ny
  KIBAOS_SOKO_MOVES=$(( KIBAOS_SOKO_MOVES + 1 ))
  return 0
}

#: One step back. The reason a stuck box is not the end of the game.
kibaos_soko_undo() {
  local last rest
  (( ${#KIBAOS_SOKO_UNDO[@]} > 0 )) || return 1
  last=${KIBAOS_SOKO_UNDO[-1]}
  unset 'KIBAOS_SOKO_UNDO[-1]'
  KIBAOS_SOKO_X=${last%%,*}
  rest=${last#*,}
  KIBAOS_SOKO_Y=${rest%%,*}
  # shellcheck disable=SC2206 # the field is a space separated list of digits
  KIBAOS_SOKO_BOXES=(${rest#*,})
  (( KIBAOS_SOKO_MOVES > 0 )) && KIBAOS_SOKO_MOVES=$(( KIBAOS_SOKO_MOVES - 1 )) || true
  return 0
}

#: Every box on a target.
kibaos_soko_won() {
  local i
  for (( i = 0; i < ${#KIBAOS_SOKO_BOXES[@]}; i++ )); do
    (( ! KIBAOS_SOKO_BOXES[i] )) || [[ ${KIBAOS_SOKO_STATIC[i]} == '.' ]] || return 1
  done
  return 0
}

#: How many levels there are, so a screen can say which one this is.
kibaos_soko_levels() { printf '%s' "${#KIBAOS_SOKO_LEVELS[@]}"; }

#: Rows of characters. Two columns per cell so the grid is close to square in
#: a terminal, where a character is about half as wide as it is tall.
kibaos_soko_rows() {
  local x y row index
  for (( y = 0; y < KIBAOS_SOKO_H; y++ )); do
    row=''
    for (( x = 0; x < KIBAOS_SOKO_W; x++ )); do
      index=$(( y * KIBAOS_SOKO_W + x ))
      if (( x == KIBAOS_SOKO_X && y == KIBAOS_SOKO_Y )); then
        row+='@ '
      elif (( KIBAOS_SOKO_BOXES[index] )); then
        [[ ${KIBAOS_SOKO_STATIC[index]} == '.' ]] && row+='* ' || row+='$ '
      else
        case ${KIBAOS_SOKO_STATIC[index]} in
          '#') row+='##' ;;
          '.') row+='. ' ;;
          *)   row+='  ' ;;
        esac
      fi
    done
    printf '%s\n' "${row%  }"
  done
}

# --------------------------------------------------------------------------
# Connect 4
# --------------------------------------------------------------------------
#
# Seven columns and two keys, which is the whole reason it is on the list: it
# needs no timing, no pointer and no chord, and it plays fine on a screen
# somebody is half watching.
#
# The opponent is deliberately weak. It takes a win it can see and blocks one
# it can see, and past that it prefers the middle and picks at random. It does
# not look two moves ahead, which is the difference between an opponent that
# is beatable while distracted and one that is not beatable at all. Losing
# every game to an installer is not a way to spend ten minutes.
KIBAOS_C4=()
KIBAOS_C4_COL=3
KIBAOS_C4_OVER=0

kibaos_c4_new() {
  local i
  KIBAOS_C4=()
  for (( i = 0; i < 42; i++ )); do KIBAOS_C4+=(0); done
  KIBAOS_C4_COL=3
  KIBAOS_C4_OVER=0
  return 0
}

#: Four of one player's counters in a line from here, in one direction.
_kibaos_c4_line() {
  local player=$1 x=$2 y=$3 dx=$4 dy=$5 i cx cy
  for (( i = 0; i < 4; i++ )); do
    cx=$(( x + dx * i ))
    cy=$(( y + dy * i ))
    (( cx >= 0 && cx < 7 && cy >= 0 && cy < 6 )) || return 1
    (( KIBAOS_C4[cy * 7 + cx] == player )) || return 1
  done
  return 0
}

#: Anywhere on the board, in any of the four directions a line can run.
kibaos_c4_wins() {
  local player=$1 x y
  for (( y = 0; y < 6; y++ )); do
    for (( x = 0; x < 7; x++ )); do
      _kibaos_c4_line "$player" "$x" "$y" 1 0 && return 0
      _kibaos_c4_line "$player" "$x" "$y" 0 1 && return 0
      _kibaos_c4_line "$player" "$x" "$y" 1 1 && return 0
      _kibaos_c4_line "$player" "$x" "$y" 1 -1 && return 0
    done
  done
  return 1
}

_kibaos_c4_open() { (( KIBAOS_C4[$1] == 0 )); }

#: Drop into a column, into the lowest free row. Refused when the column is
#: full, which is the only illegal move in this game.
_kibaos_c4_put() {
  local col=$1 player=$2 y
  for (( y = 5; y >= 0; y-- )); do
    if (( KIBAOS_C4[y * 7 + col] == 0 )); then
      KIBAOS_C4[y * 7 + col]=$player
      return 0
    fi
  done
  return 1
}

#: Take back the topmost counter in a column. Only ever used to try a move and
#: change its mind, never by a player.
_kibaos_c4_take() {
  local col=$1 y
  for (( y = 0; y < 6; y++ )); do
    if (( KIBAOS_C4[y * 7 + col] != 0 )); then
      KIBAOS_C4[y * 7 + col]=0
      return 0
    fi
  done
  return 1
}

kibaos_c4_full() {
  local col
  for (( col = 0; col < 7; col++ )); do
    (( KIBAOS_C4[col] != 0 )) || return 1
  done
  return 0
}

#: Where the opponent plays. Win, then block, then the middle, then anywhere.
_kibaos_c4_reply() {
  local col found
  for (( col = 0; col < 7; col++ )); do
    _kibaos_c4_put "$col" 2 || continue
    if kibaos_c4_wins 2; then return 0; fi
    _kibaos_c4_take "$col"
  done
  for (( col = 0; col < 7; col++ )); do
    _kibaos_c4_put "$col" 1 || continue
    found=1
    kibaos_c4_wins 1 || found=0
    _kibaos_c4_take "$col"
    if (( found )); then
      _kibaos_c4_put "$col" 2 && return 0
    fi
  done
  # The middle is worth more than the edges in this game, and preferring it is
  # the one piece of strategy in here.
  for col in 3 2 4 1 5 0 6; do
    (( RANDOM % 4 )) || continue
    _kibaos_c4_put "$col" 2 && return 0
  done
  for col in 3 2 4 1 5 0 6; do
    _kibaos_c4_put "$col" 2 && return 0
  done
  return 1
}

kibaos_c4_move() {
  case $1 in
    left)  (( KIBAOS_C4_COL > 0 )) && KIBAOS_C4_COL=$(( KIBAOS_C4_COL - 1 )) || true ;;
    right) (( KIBAOS_C4_COL < 6 )) && KIBAOS_C4_COL=$(( KIBAOS_C4_COL + 1 )) || true ;;
  esac
  return 0
}

#: One turn: the player drops, then the opponent answers, unless the player
#: has just won or filled the board.
kibaos_c4_drop() {
  (( ! KIBAOS_C4_OVER )) || return 1
  _kibaos_c4_put "$KIBAOS_C4_COL" 1 || return 1
  if kibaos_c4_wins 1; then KIBAOS_C4_OVER=1; return 0; fi
  if kibaos_c4_full; then KIBAOS_C4_OVER=3; return 0; fi
  _kibaos_c4_reply || true
  if kibaos_c4_wins 2; then KIBAOS_C4_OVER=2; return 0; fi
  if kibaos_c4_full; then KIBAOS_C4_OVER=3; return 0; fi
  return 0
}

#: Rows of characters, two columns per cell so the grid reads as square.
kibaos_c4_rows() {
  local x y row cell
  row=''
  for (( x = 0; x < 7; x++ )); do
    (( x == KIBAOS_C4_COL )) && row+='v ' || row+='  '
  done
  printf '%s\n' "${row%  }"
  for (( y = 0; y < 6; y++ )); do
    row=''
    for (( x = 0; x < 7; x++ )); do
      cell=${KIBAOS_C4[y * 7 + x]}
      case $cell in
        1) row+='O ' ;;
        2) row+='X ' ;;
        *) row+='. ' ;;
      esac
    done
    printf '%s\n' "${row%  }"
  done
}

# --------------------------------------------------------------------------
# A maze, generated fresh every time
# --------------------------------------------------------------------------
#
# Arrows only, no clock, and never the same twice, which is the one thing a
# generated puzzle has over a hand written one: there is no solution to look
# up and no level to have already done.
#
# Carved by depth first search with an explicit stack, which produces a
# perfect maze: exactly one path between any two cells, so it is always
# solvable and never has a loop to go round twice. The stack is explicit
# because bash recursion at this depth is a way to find out what the limit is.
KIBAOS_MAZE_W=9
KIBAOS_MAZE_H=5
KIBAOS_MAZE=()
KIBAOS_MAZE_COLS=0
KIBAOS_MAZE_ROWS=0
KIBAOS_MAZE_X=1
KIBAOS_MAZE_Y=1
KIBAOS_MAZE_MOVES=0

kibaos_maze_new() {
  local x y i cells visited stack top cx cy dirs dir nx ny picked
  KIBAOS_MAZE_COLS=$(( KIBAOS_MAZE_W * 2 + 1 ))
  KIBAOS_MAZE_ROWS=$(( KIBAOS_MAZE_H * 2 + 1 ))
  KIBAOS_MAZE=()
  for (( i = 0; i < KIBAOS_MAZE_COLS * KIBAOS_MAZE_ROWS; i++ )); do
    KIBAOS_MAZE+=('#')
  done
  cells=$(( KIBAOS_MAZE_W * KIBAOS_MAZE_H ))
  visited=()
  for (( i = 0; i < cells; i++ )); do visited+=(0); done

  visited[0]=1
  KIBAOS_MAZE[KIBAOS_MAZE_COLS + 1]=' '
  stack=(0)
  while (( ${#stack[@]} )); do
    top=${stack[-1]}
    cx=$(( top % KIBAOS_MAZE_W ))
    cy=$(( top / KIBAOS_MAZE_W ))
    # The four neighbours, in an order that changes every time. Always trying
    # them in the same order carves the same shape of maze from every seed.
    dirs=()
    for dir in 0 1 2 3; do dirs+=("$dir"); done
    for (( i = 3; i > 0; i-- )); do
      picked=$(( RANDOM % (i + 1) ))
      x=${dirs[i]}; dirs[i]=${dirs[picked]}; dirs[picked]=$x
    done
    picked=-1
    for dir in "${dirs[@]}"; do
      nx=$cx; ny=$cy
      case $dir in
        0) ny=$(( cy - 1 )) ;;
        1) nx=$(( cx + 1 )) ;;
        2) ny=$(( cy + 1 )) ;;
        3) nx=$(( cx - 1 )) ;;
      esac
      (( nx >= 0 && nx < KIBAOS_MAZE_W && ny >= 0 && ny < KIBAOS_MAZE_H )) || continue
      (( ! visited[ny * KIBAOS_MAZE_W + nx] )) || continue
      picked=$(( ny * KIBAOS_MAZE_W + nx ))
      # Open the cell and the wall between it and where we came from.
      KIBAOS_MAZE[(ny * 2 + 1) * KIBAOS_MAZE_COLS + (nx * 2 + 1)]=' '
      KIBAOS_MAZE[(cy + ny + 1) * KIBAOS_MAZE_COLS + (cx + nx + 1)]=' '
      visited[picked]=1
      stack+=("$picked")
      break
    done
    (( picked >= 0 )) || unset 'stack[-1]'
  done

  KIBAOS_MAZE_X=1
  KIBAOS_MAZE_Y=1
  KIBAOS_MAZE_MOVES=0
  return 0
}

#: Where the way out is, in character coordinates.
kibaos_maze_exit_x() { printf '%s' "$(( KIBAOS_MAZE_W * 2 - 1 ))"; }
kibaos_maze_exit_y() { printf '%s' "$(( KIBAOS_MAZE_H * 2 - 1 ))"; }

#: One step, refused by a wall. Two characters at a time, because a cell is
#: two characters from the next one and the character between them is the wall.
kibaos_maze_move() {
  local dir=$1 dx=0 dy=0 wall
  case $dir in
    up) dy=-1 ;; down) dy=1 ;; left) dx=-1 ;; right) dx=1 ;;
    *) return 1 ;;
  esac
  wall=$(( (KIBAOS_MAZE_Y + dy) * KIBAOS_MAZE_COLS + (KIBAOS_MAZE_X + dx) ))
  (( KIBAOS_MAZE_Y + dy >= 0 && KIBAOS_MAZE_Y + dy < KIBAOS_MAZE_ROWS )) || return 1
  (( KIBAOS_MAZE_X + dx >= 0 && KIBAOS_MAZE_X + dx < KIBAOS_MAZE_COLS )) || return 1
  [[ ${KIBAOS_MAZE[wall]} != '#' ]] || return 1
  KIBAOS_MAZE_X=$(( KIBAOS_MAZE_X + dx * 2 ))
  KIBAOS_MAZE_Y=$(( KIBAOS_MAZE_Y + dy * 2 ))
  KIBAOS_MAZE_MOVES=$(( KIBAOS_MAZE_MOVES + 1 ))
  return 0
}

kibaos_maze_won() {
  (( KIBAOS_MAZE_X == KIBAOS_MAZE_W * 2 - 1 && KIBAOS_MAZE_Y == KIBAOS_MAZE_H * 2 - 1 ))
}

#: Rows of characters. The walls are drawn solid and the corridors are blank,
#: which reads as a maze without needing colour.
kibaos_maze_rows() {
  local x y row index
  for (( y = 0; y < KIBAOS_MAZE_ROWS; y++ )); do
    row=''
    for (( x = 0; x < KIBAOS_MAZE_COLS; x++ )); do
      index=$(( y * KIBAOS_MAZE_COLS + x ))
      if (( x == KIBAOS_MAZE_X && y == KIBAOS_MAZE_Y )); then
        row+='@'
      elif (( x == KIBAOS_MAZE_W * 2 - 1 && y == KIBAOS_MAZE_H * 2 - 1 )); then
        row+='>'
      elif [[ ${KIBAOS_MAZE[index]} == '#' ]]; then
        row+='#'
      else
        row+=' '
      fi
    done
    printf '%s\n' "$row"
  done
}

# --------------------------------------------------------------------------
# A five letter word guess
# --------------------------------------------------------------------------
#
# Six tries at a five letter word. Letters, backspace and enter, which is the
# whole input model, and no clock anywhere in it.
#
# Two decisions worth writing down.
#
# **A guess is not checked against a dictionary.** The usual rule is that a
# guess has to be a real word, and enforcing that needs a word list of tens of
# thousands rather than the hundred or so here. With a short list the rule
# stops meaning "that is not a word" and starts meaning "that is not a word I
# know", which is a worse thing to be told while waiting for a disk to be
# written. Any five letters are accepted.
#
# **The result is marked, not coloured.** `=` is the right letter in the right
# place, `~` is the right letter somewhere else, `.` is not in the word at all.
# Nothing about this screen depends on colour, which is the rule for every
# screen here and is the only reason it works in plain mode and on a braille
# display.
KIBAOS_WORDS=(
  about above actor acute admit adopt after again agent agree ahead alarm album
  alert alike alive allow alone along alter among anger angle angry ankle apart
  apple apply arena argue arise armor aroma array arrow aside asset audio audit
  avoid awake award aware badly baker basic basin batch beach began begin begun
  being below bench birth black blade blame blank blast blend bless blind block
  blood board boost booth bound brain brand brass brave bread break breed brick
  bride brief bring broad broke brown brush build built bunch burnt burst cabin
  cable candy canal cargo carry carve catch cause cease chain chair chalk charm
  chart chase cheap check chess chest chief child chill china chose civil claim
  clean clear clerk click cliff climb clock close cloth cloud coach coast could
  count court cover crack craft crash cream crime cross crowd crown crude curve
  cycle daily dance dated dealt death debut delay dense depth doing doubt dozen
  draft drain drama drawn dream dress dried drift drink drive drove dying eager
  eagle early earth eight elder elect empty enemy enjoy enter entry equal error
  event every exact exist extra faith false fault favor feast fence fever field
  fifth fight final first flame flash fleet flesh float flood floor flour fluid
  focus force forge forth forty forum found frame fresh front frost fruit fully
  funny giant given glass globe glory grace grade grain grand grant grape grasp
  grass grave great green greet grief gross group grown guard guess guest guide
  habit happy harsh haste heart heavy hedge hello hence hobby honey honor horse
  hotel house human humor ideal image imply index inner input issue ivory joint
  judge juice knife knock known label labor large laser later laugh layer learn
  lease least leave legal lemon level light limit linen liver lobby local lodge
  logic loose lower loyal lucky lunar lunch magic major maker maple march match
  maybe mayor meant medal media mercy merit metal meter midst might minor minus
  mixed model money month moral motor mount mouse mouth movie music naked nerve
  never newly night noble noise north noted novel nurse occur ocean offer often
  onion order other ought ounce outer owner paint panel paper party pause peace
  pearl phase phone photo piano piece pilot pitch place plain plane plant plate
  point polar porch pound power press price pride prime print prior prize probe
  proof proud prove pulse punch pupil purse queen query quest queue quick quiet
  quite quota radio raise rally range rapid ratio reach ready realm rebel refer
  reign relax relay renew reply rider ridge right rigid rival river roast robot
  rocky roman rough round route royal rural saint salad sales sauce scale scene
  scope score sense serve seven shade shaft shall shape share sharp sheep sheet
  shelf shell shift shine shirt shock shoot shore short shown sight silly since
  siren sixth skill slate sleep slide slope small smart smell smile smoke snake
  solar solid solve sound south space spare spark speak speed spell spend spent
  spice spine spite split spoke sport spray squad stack staff stage stair stake
  stamp stand stare start state steam steel steep steer stern stick stiff still
  stock stone stood store storm story stove strap straw strip stuck study stuff
  style sugar suite sunny super sweep sweet swift swing sword table taken tally
  taste teach tempo tenth thank theft their theme there thick thief thing think
  third those three throw thumb tiger tight timer title toast today token tooth
  topic torch total touch tough tower trace track trade trail train trait trash
  treat trend trial tribe trick tried tripe trust truth twice twist ultra uncle
  under union unite unity until upper upset urban usage usual vague valid value
  vapor vault venue verse video vigor villa vinyl virus visit vital vivid vocal
  voice voter wagon waist waste watch water weigh weird whale wheat wheel where
  which while white whole whose widow width witch woman world worry worse worth
  would wound wrist write wrong wrote yield young youth
)

KIBAOS_WORD=''
KIBAOS_WORD_GUESSES=()
KIBAOS_WORD_MARKS=()
KIBAOS_WORD_INPUT=''
KIBAOS_WORD_OVER=0
KIBAOS_WORD_TRIES=6

kibaos_word_new() {
  local word
  # Anything that is not five letters is a typing mistake in the list above,
  # and one of those would make a round unwinnable.
  while true; do
    word=${KIBAOS_WORDS[RANDOM % ${#KIBAOS_WORDS[@]}]}
    (( ${#word} == 5 )) && break
  done
  KIBAOS_WORD=$word
  KIBAOS_WORD_GUESSES=()
  KIBAOS_WORD_MARKS=()
  KIBAOS_WORD_INPUT=''
  KIBAOS_WORD_OVER=0
  return 0
}

#: Mark one guess against the answer.
#
# Two passes, and the second one is the reason. A letter guessed twice when
# the answer holds it once must come back right in one place and absent in the
# other, so exact matches are taken out of the pool before anything else is
# allowed to claim a letter. One pass marks both of them present and tells
# somebody there are two of a letter when there is one.
kibaos_word_mark() {
  local guess=$1 answer=$2 i j ch marks=''
  local -a used=(0 0 0 0 0)
  for (( i = 0; i < 5; i++ )); do
    if [[ ${guess:i:1} == "${answer:i:1}" ]]; then
      marks+='='
      used[i]=1
    else
      marks+='?'
    fi
  done
  for (( i = 0; i < 5; i++ )); do
    [[ ${marks:i:1} == '?' ]] || continue
    ch=${guess:i:1}
    for (( j = 0; j < 5; j++ )); do
      (( ! used[j] )) || continue
      [[ ${answer:j:1} == "$ch" ]] || continue
      used[j]=1
      marks=${marks:0:i}'~'${marks:i+1}
      break
    done
    [[ ${marks:i:1} != '?' ]] || marks=${marks:0:i}'.'${marks:i+1}
  done
  printf '%s' "$marks"
}

kibaos_word_type() {
  local ch=$1
  (( ! KIBAOS_WORD_OVER )) || return 1
  [[ $ch == [a-zA-Z] ]] || return 1
  (( ${#KIBAOS_WORD_INPUT} < 5 )) || return 1
  KIBAOS_WORD_INPUT+=${ch,,}
  return 0
}

kibaos_word_rub() {
  (( ! KIBAOS_WORD_OVER )) || return 1
  [[ -n $KIBAOS_WORD_INPUT ]] || return 1
  KIBAOS_WORD_INPUT=${KIBAOS_WORD_INPUT%?}
  return 0
}

kibaos_word_enter() {
  local marks
  (( ! KIBAOS_WORD_OVER )) || return 1
  (( ${#KIBAOS_WORD_INPUT} == 5 )) || return 1
  marks=$(kibaos_word_mark "$KIBAOS_WORD_INPUT" "$KIBAOS_WORD")
  KIBAOS_WORD_GUESSES+=("$KIBAOS_WORD_INPUT")
  KIBAOS_WORD_MARKS+=("$marks")
  KIBAOS_WORD_INPUT=''
  if [[ $marks == '=====' ]]; then
    KIBAOS_WORD_OVER=1
  elif (( ${#KIBAOS_WORD_GUESSES[@]} >= KIBAOS_WORD_TRIES )); then
    KIBAOS_WORD_OVER=2
  fi
  return 0
}

#: Rows of characters: each guess, then its marks underneath it.
kibaos_word_rows() {
  local i guess
  for (( i = 0; i < ${#KIBAOS_WORD_GUESSES[@]}; i++ )); do
    guess=${KIBAOS_WORD_GUESSES[i]}
    printf '%s\n' "${guess^^}"
    printf '%s\n' "${KIBAOS_WORD_MARKS[i]}"
  done
  if (( ! KIBAOS_WORD_OVER )); then
    printf '%s\n' "$(printf '%-5s' "${KIBAOS_WORD_INPUT^^}" | tr ' ' '_')"
    printf '%s\n' ''
  fi
}
