#!/usr/bin/env fish
#
# palette-inline.fish — preview / command / edit pane script
#
# This script is launched by the `palette` function in a dedicated tmux pane.
# It is fully self-contained and reads IPC paths from $PALETTE_CFG.
#
# Environment
#   PALETTE_CFG   — path to a 4-line config file written by the palette function
#                   line 1: sel_file       (written by fzf on focus)
#                   line 2: cmt_file       (written by fzf on enter)
#                   line 3: chld_id_file   (fzf pane id, written by palette )
#                   line 4: prev_id_file   (this pane's id, written by palette)
#   PALETTE_FILE  — path to the JSON colour file (set by palette function)

# ═══════════════════════════════════════════════════════════════════════════
# CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════

set -q PALETTE_FILE; or set -g PALETTE_FILE $HOME/.palette.json

# ═══════════════════════════════════════════════════════════════════════════
# INTERNAL HELPERS
# ═══════════════════════════════════════════════════════════════════════════

# ── Single keypress read (raw mode) ─────────────────────────────────────
function _cb_get_key
    set -l state (stty -g 2>/dev/null)
    stty raw -echo 2>/dev/null
    set -l key (dd bs=1 count=1 2>/dev/null)
    stty "$state" 2>/dev/null
    echo "$key"
end

# ── RGB channel adjust ──────────────────────────────────────────────────
function _cb_adjust_channel -a hex channel delta
    set -l parts (string match -r \
        'rgb\s*\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)' \
        (pastel format rgb $hex))
    if test (count $parts) -ne 4
        return 1
    end
    set -l r $parts[2]
    set -l g $parts[3]
    set -l b $parts[4]
    switch $channel
        case r
            set r (math $r + $delta)
        case g
            set g (math $g + $delta)
        case b
            set b (math $b + $delta)
    end
    if test $r -gt 255
        set r 255
    else if test $r -lt 0
        set r 0
    end
    if test $g -gt 255
        set g 255
    else if test $g -lt 0
        set g 0
    end
    if test $b -gt 255
        set b 255
    else if test $b -lt 0
        set b 0
    end
    pastel color "rgb($r, $g, $b)" | pastel format hex
end

# ── Preview: render a color swatch ──────────────────────────────────────
function _cb_preview -a hex paired_hex
    pastel color $hex 2>/dev/null; or true
    echo -n "  "
    set_color $hex
    echo "extended example text"
    set_color normal
    echo -n "  "
    set_color (pastel textcolor $hex | pastel format hex)
    set_color -b $hex
    echo "extended example text"
    set_color normal
    if test -n "$paired_hex"
        set -l pname (jq -r --arg h "$paired_hex" '.[] | select(.[1]==$h) | .[0]' $PALETTE_FILE 2>/dev/null)
        if test -z "$pname"
            set pname custom
        end
        echo -n "  "
        set_color $hex
        set_color -b $paired_hex
        echo "this text on $pname background"
        set_color normal
        echo -n "  "
        set_color $paired_hex
        set_color -b $hex
        echo "$pname text on this background"
        set_color normal
    end
end

# ── Preview with optional message ───────────────────────────────────────
function _cb_redraw -a hex paired msg
    clear
    _cb_preview $hex $paired
    echo
    if test -n "$msg"
        set_color e49641
        echo $msg
        set_color normal
        echo
    end
end

# ── Pick a pair color via fzf ───────────────────────────────────────────
function _cb_pick_pair_color
    set -l name (jq -r '.[] | .[0]' $PALETTE_FILE \
        | fzf --height 40% --layout=reverse --no-sort -e --border --cycle)
    if test -n "$name"
        jq -r --arg k "$name" '.[] | select(.[0]==$k) | .[1]' $PALETTE_FILE
    end
end

# ── Adjustment dispatcher (operates on globals $current / $paired) ──────
function _cb_adjust -a key
    switch $key
        case r
            set -g current (_cb_adjust_channel $current r 1)
        case R
            set -g current (_cb_adjust_channel $current r -1)
        case g
            set -g current (_cb_adjust_channel $current g 1)
        case G
            set -g current (_cb_adjust_channel $current g -1)
        case b
            set -g current (_cb_adjust_channel $current b 1)
        case B
            set -g current (_cb_adjust_channel $current b -1)
        case j
            set -g current (pastel rotate 1 $current | pastel format hex)
        case J
            set -g current (pastel rotate -- -1 $current | pastel format hex)
        case l
            set -g current (pastel lighten 0.01 $current | pastel format hex)
        case L
            set -g current (pastel darken 0.01 $current | pastel format hex)
        case k
            set -g current (pastel saturate 0.01 $current | pastel format hex)
        case K
            set -g current (pastel desaturate 0.01 $current | pastel format hex)
        case '*'
            return 1
    end
    _cb_redraw $current $paired ""
    return 0
end

# ═══════════════════════════════════════════════════════════════════════════
# IPC SETUP — read config from PALETTE_CFG (written by the palette function)
# ═══════════════════════════════════════════════════════════════════════════

set -g sel_file (sed -n '1p' $PALETTE_CFG)
set -g cmt_file (sed -n '2p' $PALETTE_CFG)
set -g chld_id_file (sed -n '3p' $PALETTE_CFG)
set -g prev_id_file (sed -n '4p' $PALETTE_CFG)
set -g names_file (sed -n '5p' $PALETTE_CFG)
set -g restart_file (sed -n '6p' $PALETTE_CFG)

# ── Wait for the fzf pane to register its tmux pane id ──
set -l chld_pane (cat $chld_id_file 2>/dev/null)
if test -z "$chld_pane"
    for i in (seq 1 50)
        sleep 0.1
        set chld_pane (cat $chld_id_file 2>/dev/null)
        if test -n "$chld_pane"
            break
        end
    end
end

# ═══════════════════════════════════════════════════════════════════════════
# STATE
# ═══════════════════════════════════════════════════════════════════════════

set -g last_sel ""
set -g mode preview
set -g current ""
set -g paired ""
set -g edit_base_name ""
set -g _cb_save_pending ""

# ═══════════════════════════════════════════════════════════════════════════
# MAIN LOOP
# ═══════════════════════════════════════════════════════════════════════════

while true

    # PENDING SAVE
    if test -n "$_cb_save_pending"
        and test "$_cb_save_pending" != ""
        printf "\e[4A\e[J"

        set -l save_name ""
        if test -n "$edit_base_name"
            and test "$edit_base_name" != custom
            echo -n "Overwrite \"$edit_base_name\"? [y/Name]: "
            set -l answer (head -n 1)
            set answer (string trim -- $answer)
            switch $answer
                case y Y yes YES
                    set save_name "$edit_base_name"
                case '*'
                    if test -n "$answer"
                        set save_name "$answer"
                    else
                        set save_name ""
                    end
            end
        else
            echo -n "Name: "
            set save_name (head -n 1)
            set save_name (string trim -- $save_name)
        end

        if test -n "$save_name"
            set -l clean (pastel format hex $current)
            if test -z "$clean"
                set -g _cb_status "Error: pastel failed"
                set -g _cb_save_pending ""
                continue
            end
            jq --arg n "$save_name" --arg h "$clean" \
                'if any(.[]; .[0] == $n)
                 then map(if .[0] == $n then [$n, $h] else . end)
                 else . + [[$n, $h]] end' \
                $PALETTE_FILE \
            | jq -r '24 as $w | [.[] | "  [\"\(.[0])\", \(" " * ([$w - (.[0] | length), 0] | max))\"\(.[1])\"]"] as $lines | "[\n" + ($lines | join(",\n")) + "\n]"' \
                >$PALETTE_FILE.tmp
            and mv $PALETTE_FILE.tmp $PALETTE_FILE
            and begin
                set -g _cb_status "$save_name written"
                printf '%s\n' '--- Enter a new color ---' >$names_file
                jq -r '.[] | .[0]' $PALETTE_FILE >>$names_file
                echo restart >$restart_file
                tmux send-keys -t $chld_pane F5
            end
            or begin
                rm -f $PALETTE_FILE.tmp 2>/dev/null
                set -g _cb_status "Error: failed to save \"$save_name\""
            end
        else
            set -g _cb_status ""
        end

        set -g _cb_save_pending ""
        continue
    end

    # ──────────────────────────────────────────────────────────────────────
    # MODE: PREVIEW  — show a live colour preview as the user browses fzf
    # ──────────────────────────────────────────────────────────────────────
    if test "$mode" = preview

        # ── Selection changed? Refresh the preview ──
        set -l sel (cat $sel_file 2>/dev/null)
        if test -n "$sel"
            and test "$sel" != "$last_sel"
            and test "$sel" != '--- Enter a new color ---'
            clear
            set -l hex (jq -r --arg k "$sel" \
                '.[] | select(.[0]==$k) | .[1]' $PALETTE_FILE 2>/dev/null)
            if test -n "$hex"
                _cb_preview $hex ""
                echo
            end
            set last_sel "$sel"
        end

        # ── Commit (Enter in fzf) ──
        set -l cmt (cat $cmt_file 2>/dev/null)
        if test -n "$cmt"
            and test "$cmt" != '--- Enter a new color ---'
            set current (jq -r --arg k "$cmt" \
                '.[] | select(.[0]==$k) | .[1]' $PALETTE_FILE)
            set paired ""
            set mode command
        else if test "$cmt" = '--- Enter a new color ---'
            set current (pastel random -n 1 | pastel format hex)
            set paired ""
            set mode command
        end
    end

    # ──────────────────────────────────────────────────────────────────────
    # MODE: COMMAND — adjust the colour, copy it, edit, or flip
    # ──────────────────────────────────────────────────────────────────────
    if test "$mode" = command
        clear
        _cb_preview $current $paired
        echo

        while true
            echo "neo[w]im  [e]dit  [i]nput  f[z]f"
            echo "[p]air   [P]air-clear"
            echo "[s]ex   [c]rgb   [d]hsl   [f]lip"

            set -l key (_cb_get_key)
            switch $key
                case w
                    $EDITOR $PALETTE_FILE
                    continue

                case e
                    set edit_base_name (jq -r --arg h "$current" \
                        '.[] | select(.[1]==$h) | .[0]' $PALETTE_FILE 2>/dev/null)
                    if test -z "$edit_base_name"
                        set edit_base_name custom
                    end
                    set mode edit
                    break

                case i
                    read -l hex -P "hex: "
                    if test -z "$hex"
                        continue
                    end
                    set -l hex_pattern "^#[0-9a-fA-F]{6}\$"
                    if not string match -r $hex_pattern $hex
                        _cb_redraw $current $paired "invalid hex"
                        continue
                    end
                    set current $hex
                    set paired ""
                    set edit_base_name custom
                    set mode edit
                    break

                case z
                    echo -n >$cmt_file
                    tmux select-pane -t $chld_pane
                    set mode preview
                    set last_sel ""
                    break

                case s
                    echo $current | wl-copy -n
                    _cb_redraw $current $paired "$current copied"
                    continue

                case c
                    set -l rgb (pastel format rgb $current)
                    echo $rgb | wl-copy -n
                    _cb_redraw $current $paired "$rgb copied"
                    continue

                case d
                    set -l hsl (pastel format hsl $current)
                    echo $hsl | wl-copy -n
                    _cb_redraw $current $paired "$hsl copied"
                    continue

                case f
                    set current (pastel complement $current | pastel format hex)
                    _cb_redraw $current $paired "flip $current"
                    continue

                case p
                    set -l pc (_cb_pick_pair_color)
                    if test -n "$pc"
                        set paired $pc
                        _cb_redraw $current $paired "paired: $pc"
                    else
                        _cb_redraw $current $paired ""
                    end
                    continue

                case P
                    set paired ""
                    _cb_redraw $current $paired "pair cleared"
                    continue
            end
            break
        end
    end

    # ──────────────────────────────────────────────────────────────────────
    # MODE: EDIT — fine-tune channels and save
    # ──────────────────────────────────────────────────────────────────────
    if test "$mode" = edit
        clear
        _cb_preview $current $paired
        echo

        if test -n "$edit_base_name"
            set_color e49641
            echo "editing: $edit_base_name"
            set_color normal
        end

        if set -q _cb_status
            and test -n "$_cb_status"
            set_color e49641
            echo $_cb_status
            set_color normal
            set -e _cb_status
        end
        echo

        while true
            echo "[p]air   [P]air-clear"
            echo "[w]rite (save)  [e]xit edit  f[z]f"
            echo "+[r]ed -[R]ed   +[g]reen -[G]green   +[b]lue -[B]lue"
            echo "+[j]ue -[J]ue   +[l]ight -[L]light   +sa[k]urate -sa[K]urate"

            set -l key (_cb_get_key)
            switch $key
                case w
                    set -g _cb_save_pending yes
                    break

                case e
                    set mode command
                    break

                case z
                    echo -n >$cmt_file
                    tmux select-pane -t $chld_pane
                    set mode preview
                    set last_sel ""
                    break

                case p
                    set -l pc (_cb_pick_pair_color)
                    if test -n "$pc"
                        set paired $pc
                        _cb_redraw $current $paired "paired: $pc"
                    else
                        _cb_redraw $current $paired ""
                    end
                    continue

                case P
                    set paired ""
                    _cb_redraw $current $paired "pair cleared"
                    continue

                case r R g G b B j J l L k K
                    _cb_adjust $key
                    continue
            end
            break
        end
    end

    sleep 0.1
end
