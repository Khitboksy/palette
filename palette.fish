# palette.fish - source this file to get the `palette` command
#   source path/to/palette.fish && palette
#
# Configuration
#   $PALETTE_FILE  - path to the JSON colour file (default: $HOME/.palette.json)
#   $EDITOR        — editor opened by the [w] key in command mode

# ── Configuration defaults ──────────────────────────────────────────────
set -q PALETTE_FILE; or set -gx PALETTE_FILE $HOME/.palette.json

# INTERNAL HELPERS

# Color grid: display all named colors in the main pane
function _cb_show_all
    jq -r '.[] | "\(.[0])\t\(.[1])"' $PALETTE_FILE | while read -l name hex
        set_color $hex
        printf "%-22s" "$name"
        set_color normal
        printf "  "
        set_color -b $hex
        set_color (pastel textcolor $hex | pastel format hex)
        printf "%-22s" "$name"
        set_color normal
        echo
    end
end

# Preview: render a color swatch
function _cb_preview -a hex paired_hex
    pastel color $hex 2>/dev/null; or true
    set_color $hex
    echo "  extended example text"
    set_color normal
    echo -n "  "
    set_color (pastel textcolor $hex | pastel format hex)
    set_color -b $hex
    echo "extended example text"
    set_color normal
    if test -n "$paired_hex"
        set -l pname (jq -r --arg h "$paired_hex" \
            '.[] | select(.[1]==$h) | .[0]' $PALETTE_FILE 2>/dev/null)
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

# ── Save color to palette file (jq-based atomic write) ──────────────────
function _cb_save_color -a hex name
    set -l clean (pastel format hex $hex)
    jq --arg n "$name" --arg h "$clean" \
        'if any(.[]; .[0] == $n)
         then map(if .[0] == $n then [$n, $h] else . end)
         else . + [[$n, $h]] end' \
        $PALETTE_FILE >$PALETTE_FILE.tmp
    and mv $PALETTE_FILE.tmp $PALETTE_FILE
    or begin
        rm -f $PALETTE_FILE.tmp 2>/dev/null
        return 1
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

# ── Cursor-aware confirmation message (unused, kept for reference) ──────
function _cb_confirm_msg -a msg
    printf "\e[2K\r"
    printf "\e[A\e[2K\r"
    set_color e49641
    echo "$msg"
    set_color normal
    printf "\e[2F\e[2K\r\e[F\e[2K\r"
end

# ═══════════════════════════════════════════════════════════════════════════
# ENTRY POINT
# ═══════════════════════════════════════════════════════════════════════════

# ── Tmux three-pane palette layout ──────────────────────────────────────
function palette
    # Find the inline script next to this file
    set -l script_dir (dirname (status filename))
    set -l inline_source "$script_dir/palette-inline.fish"

    if not test -f "$inline_source"
        echo "palette: cannot find palette-inline.fish next to palette.fish" >&2
        echo "       (expected at $inline_source)" >&2
        return 1
    end

    set -l current_pane (tmux display-message -p '#{pane_id}')

    # ── Temp files for IPC ──
    set -l sel_file      (mktemp /tmp/palette-sel.XXXXXX)
    set -l cmt_file      (mktemp /tmp/palette-commit.XXXXXX)
    set -l res_file      (mktemp -u /tmp/palette-result.XXXXXX)
    set -l chld_id_file  (mktemp /tmp/palette-child-id.XXXXXX)
    set -l prev_id_file  (mktemp /tmp/palette-preview-id.XXXXXX)
    set -l names_file    (mktemp /tmp/palette-names.XXXXXX)
    set -l restart_file  (mktemp /tmp/palette-restart.XXXXXX)

    # ── Write initial colour names to names_file ──
    printf '%s\n' '--- Enter a new color ---' > $names_file
    jq -r '.[] | .[0]' $PALETTE_FILE >> $names_file

    # ── Config file: IPC paths for the inline script ──
    set -l cfg_file (mktemp /tmp/palette-cfg.XXXXXX)
    printf '%s\n' "$sel_file"     > "$cfg_file"
    printf '%s\n' "$cmt_file"     >> "$cfg_file"
    printf '%s\n' "$chld_id_file" >> "$cfg_file"
    printf '%s\n' "$prev_id_file" >> "$cfg_file"
    printf '%s\n' "$names_file"   >> "$cfg_file"  # line 5
    printf '%s\n' "$restart_file" >> "$cfg_file"  # line 6

    # ── Copy inline script to temp so tmux can find it ──
    set -l inline_script (mktemp /tmp/palette-inline.XXXXXX)
    cp "$inline_source" "$inline_script"

    # ── Create three-pane layout ──
    #   current_pane (top-left):   color grid
    #   child_pane   (bottom 30%): fzf colour picker
    #   preview_pane (top-right):  palette-inline.fish (preview / command / edit)

    set -l picker_cmd "cat $names_file \
        | fzf --height=100% --no-sort -e --no-mouse --border --cycle --layout=reverse \
              --bind='focus:execute-silent(echo {} > $sel_file.tmp; and mv $sel_file.tmp $sel_file)' \
              --bind='enter:execute-silent(echo {} > $cmt_file.tmp; and mv $cmt_file.tmp $cmt_file; and tmux select-pane -t (cat $prev_id_file))' \
              > $res_file.tmp; and mv $res_file.tmp $res_file"

    set -l child_pane (tmux split-window -v -p 30 -P -F '#{pane_id}' \
        -t $current_pane "$picker_cmd")
    echo $child_pane > $chld_id_file

    set -l preview_pane (tmux split-window -h -p 59 -P -F '#{pane_id}' \
        -t $current_pane \
        "env PALETTE_FILE=$PALETTE_FILE PALETTE_CFG=$cfg_file fish $inline_script")
    echo $preview_pane > $prev_id_file

    tmux select-pane -t $child_pane
    _cb_show_all
    set_color normal
    echo

    # ── Wait for fzf to finish (handles live restarts too) ──
    while true
        if test -f $res_file
            break
        end

        # ── Restart fzf when inline script signals a save ──
        if test -f $restart_file
            rm -f $restart_file

            # Kill old fzf pane
            tmux kill-pane -t $child_pane 2>/dev/null; or true

            # Update names_file from palette (inline script already wrote it)
            printf '%s\n' '--- Enter a new color ---' > $names_file
            jq -r '.[] | .[0]' $PALETTE_FILE >> $names_file

            # Clear any stale result file
            rm -f $res_file $res_file.tmp

            # Wait for pane to fully die
            sleep 0.3

            # Start new fzf pane with updated names
            set -l picker_cmd "cat $names_file \
                | fzf --height=100% --no-sort -e --no-mouse --border --cycle --layout=reverse \
                      --bind='focus:execute-silent(echo {} > $sel_file.tmp; and mv $sel_file.tmp $sel_file)' \
                      --bind='enter:execute-silent(echo {} > $cmt_file.tmp; and mv $cmt_file.tmp $cmt_file; and tmux select-pane -t (cat $prev_id_file))' \
                      > $res_file.tmp; and mv $res_file.tmp $res_file"

            set -l child_pane (tmux split-window -v -p 30 -P -F '#{pane_id}' \
                -t $current_pane "$picker_cmd")
            echo $child_pane > $chld_id_file

            # Refresh the colour grid in the main pane
            clear
            _cb_show_all
            set_color normal
            echo

            continue
        end

        if not tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qxF "$child_pane"
            break
        end

        sleep 0.2
    end

    # ── Cleanup ──
    tmux kill-pane -t $preview_pane 2>/dev/null; or true
    rm -f $sel_file $sel_file.tmp \
          $cmt_file $cmt_file.tmp \
          $res_file $res_file.tmp \
          $chld_id_file $prev_id_file \
          $names_file $restart_file \
          $cfg_file $inline_script 2>/dev/null
end
